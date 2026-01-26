from flask import Flask, render_template, request, redirect, url_for, flash, session, send_file, jsonify, Response
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from datetime import datetime
import os
import csv
import json
import pandas as pd
import uuid
import threading
import re
import time
import boto3
from botocore.exceptions import ClientError, TokenRetrievalError, CredentialRetrievalError
from botocore.config import Config
import pydicom
from PIL import Image
import io
import base64
import ssl
import urllib.request
import urllib.error

app = Flask(__name__)
app.config['SECRET_KEY'] = 'your-secret-key-change-this-in-production'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///users.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# File upload configuration
UPLOAD_FOLDER = 'uploads'
ALLOWED_EXTENSIONS = {'csv'}
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

# Create uploads directory
os.makedirs('uploads', exist_ok=True)

# File locks for preventing race conditions during saves
file_locks = {}

# Create upload directory if it doesn't exist
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# AWS Configuration
# Get AWS_PROFILE from environment, default to 'default' if not set
# But if it's explicitly set to empty string, use None to use default credentials (EC2 IAM role)
def get_aws_profile():
    """Get AWS profile, ensuring empty strings are converted to None"""
    aws_profile_env = os.environ.get('AWS_PROFILE')
    # If not set or empty string, return None to use default credentials (EC2 IAM role)
    if not aws_profile_env or aws_profile_env.strip() == '':
        return None
    return aws_profile_env.strip()

AWS_PROFILE = get_aws_profile()
AWS_VERIFY_SSL = os.environ.get('AWS_VERIFY_SSL', 'true').lower() != 'false'

def get_s3_client():
    """Get S3 client configured with AWS SSO profile and SSL settings"""
    s3_config = Config(
        signature_version='s3v4',
        retries={'max_attempts': 3, 'mode': 'standard'}
    )
    
    try:
        # Get current AWS_PROFILE (in case it changed)
        current_profile = get_aws_profile()
        
        # Create boto3 session - NEVER pass empty string to boto3.Session()
        # Only pass profile_name if we have a valid, non-empty profile
        if current_profile:
            session = boto3.Session(profile_name=current_profile)
        else:
            # Use default credential chain (will use EC2 instance IAM role via metadata service)
            # This is the correct way to use EC2 instance IAM role
            session = boto3.Session()
        
        # Create S3 client with appropriate SSL configuration
        if not AWS_VERIFY_SSL:
            import urllib3
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
            s3_client = session.client('s3', config=s3_config, verify=False)
        else:
            s3_client = session.client('s3', config=s3_config)
        
        return s3_client
    except (TokenRetrievalError, CredentialRetrievalError) as e:
        error_msg = str(e).lower()
        # Only show SSO error if we're actually using a profile
        if AWS_PROFILE and 'sso' in error_msg and ('expired' in error_msg or 'invalid' in error_msg):
            raise Exception(f"AWS SSO session expired. Please run: aws sso login --profile {AWS_PROFILE}")
        # If no profile, try default credentials
        if not AWS_PROFILE:
            try:
                session = boto3.Session()
                s3_client = session.client('s3', config=s3_config)
                return s3_client
            except Exception as default_error:
                raise Exception(f"Failed to get AWS credentials. Error: {str(default_error)}")
        raise
    except Exception as e:
        error_str = str(e).lower()
        # Only show SSO error if we're actually using a profile
        if AWS_PROFILE and 'sso' in error_str and ('expired' in error_str or 'invalid' in error_str):
            raise Exception(f"AWS SSO session expired. Please run: aws sso login --profile {AWS_PROFILE}")
        # If profile not found and we're not using a profile, try default credentials
        if 'profile' in error_str and 'could not be found' in error_str and not AWS_PROFILE:
            try:
                session = boto3.Session()
                s3_client = session.client('s3', config=s3_config)
                return s3_client
            except Exception as default_error:
                raise Exception(f"Failed to get AWS credentials. Error: {str(default_error)}")
        raise

db = SQLAlchemy(app)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

# User model
class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(120), nullable=False)
    first_name = db.Column(db.String(50), nullable=False)
    last_name = db.Column(db.String(50), nullable=False)
    organization = db.Column(db.String(100), nullable=False)
    position = db.Column(db.String(100), nullable=False)
    phone = db.Column(db.String(20), nullable=False)
    is_approved = db.Column(db.Boolean, default=False)
    is_admin = db.Column(db.Boolean, default=False)
    is_manager = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime, nullable=True)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)
    
    @property
    def role(self):
        """Get user role as string"""
        if self.is_admin:
            return 'admin'
        elif self.is_manager:
            return 'manager'
        else:
            return 'user'

# UserManager model - tracks which users are assigned to which managers
class UserManager(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    manager_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    assigned_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    # Relationships
    manager = db.relationship('User', foreign_keys=[manager_id], backref='managed_users')
    user = db.relationship('User', foreign_keys=[user_id], backref='managers')
    
    # Ensure unique manager-user relationships
    __table_args__ = (db.UniqueConstraint('manager_id', 'user_id', name='unique_manager_user'),)

# Annotation File model
class AnnotationFile(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(255), nullable=False)
    original_filename = db.Column(db.String(255), nullable=False)
    file_path = db.Column(db.String(500), nullable=False)
    editable_columns = db.Column(db.Text, nullable=False)  # JSON string of editable column names
    column_configs = db.Column(db.Text, nullable=True)  # JSON string of column configurations (type, dropdown_values)
    visible_columns = db.Column(db.Text, nullable=True)  # JSON string of visible column names
    image_path_column = db.Column(db.String(255), nullable=True)  # Column name containing image paths
    image_visible = db.Column(db.Boolean, default=False)  # Whether to show image icon
    created_by = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    manager_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=True)  # Manager who owns this file
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    is_active = db.Column(db.Boolean, default=True)
    
    # Relationships
    creator = db.relationship('User', foreign_keys=[created_by], backref='created_files')
    manager = db.relationship('User', foreign_keys=[manager_id], backref='managed_files')
    assignments = db.relationship('AnnotationAssignment', backref='annotation_file', cascade='all, delete-orphan')

# Annotation Assignment model
class AnnotationAssignment(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    file_id = db.Column(db.Integer, db.ForeignKey('annotation_file.id'), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    assigned_at = db.Column(db.DateTime, default=datetime.utcnow)
    status = db.Column(db.String(20), default='assigned')  # assigned, in_progress, completed
    completed_at = db.Column(db.DateTime, nullable=True)
    user_file_path = db.Column(db.String(500), nullable=True)  # Path to user's copy
    
    # Relationships
    user = db.relationship('User', backref='assignments')
    
    # Ensure one assignment per user per file
    __table_args__ = (db.UniqueConstraint('file_id', 'user_id', name='unique_file_user_assignment'),)

class Notification(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    admin_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=True)  # Can be null for manager notifications
    manager_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=True)  # Can be null for admin notifications
    assignment_id = db.Column(db.Integer, db.ForeignKey('annotation_assignment.id'), nullable=False)
    message = db.Column(db.String(500), nullable=False)
    is_read = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    admin = db.relationship('User', foreign_keys=[admin_id], backref='admin_notifications')
    manager = db.relationship('User', foreign_keys=[manager_id], backref='manager_notifications')
    assignment = db.relationship('AnnotationAssignment', backref='notifications')

# Annotation Row model - stores annotation data for each assignment
class AnnotationRow(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    assignment_id = db.Column(db.Integer, db.ForeignKey('annotation_assignment.id'), nullable=False)
    row_index = db.Column(db.Integer, nullable=False)
    data = db.Column(db.Text, nullable=False)  # JSON string of row data
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    # Relationship
    assignment = db.relationship('AnnotationAssignment', backref='rows')

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

def allowed_file(filename):
    """Check if file extension is allowed"""
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def get_csv_columns(file_path):
    """Get column names from CSV file"""
    try:
        df = pd.read_csv(file_path)
        return df.columns.tolist()
    except Exception as e:
        print(f"Error reading CSV: {e}")
        return []

def get_user_filename(original_filename, username):
    """Generate consistent user filename: original_filename_username.csv"""
    name, ext = os.path.splitext(original_filename)
    return f"{name}_{username}{ext}"


def create_user_copy(original_file_path, username, original_filename):
    """Create a user-specific copy of the CSV file"""
    try:
        # Check if original file exists
        if not os.path.exists(original_file_path):
            print(f"Original file does not exist: {original_file_path}")
            return None
            
        # Create filename using consistent naming convention
        user_filename = get_user_filename(original_filename, username)
        user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], user_filename)
        
        # Copy the original file with proper handling of empty values and malformed CSV
        try:
            df = pd.read_csv(original_file_path, dtype=str, keep_default_na=False)
        except pd.errors.ParserError as e:
            print(f"CSV parsing error, trying with error handling: {e}")
            # Try with more lenient parsing
            df = pd.read_csv(original_file_path, dtype=str, keep_default_na=False, 
                           on_bad_lines='skip', engine='python')
        
        # Clean any existing multi-choice values to remove newlines
        for col in df.columns:
            df[col] = df[col].apply(lambda x: str(x).replace('\n', '').replace('\r', '') if pd.notna(x) else x)
            df[col] = df[col].apply(lambda x: re.sub(r'\s*,\s*', ',', str(x)) if pd.notna(x) else x)
            df[col] = df[col].apply(lambda x: re.sub(r',+', ',', str(x)) if pd.notna(x) else x)
            df[col] = df[col].apply(lambda x: str(x).strip(', ').strip() if pd.notna(x) else x)
        
        df.to_csv(user_file_path, index=False, na_rep='', quoting=1, escapechar='\\')  # Use QUOTE_ALL
        
        # Return relative path for database storage
        relative_path = os.path.relpath(user_file_path, app.config['UPLOAD_FOLDER'])
        return relative_path
    except Exception as e:
        print(f"Error creating user copy: {e}")
        return None

def create_admin_user():
    """Create admin user if it doesn't exist"""
    admin = User.query.filter_by(username='admin').first()
    if not admin:
        admin = User(
            username='admin',
            email='admin@annotation.com',
            first_name='Admin',
            last_name='User',
            organization='System',
            position='Administrator',
            phone='000-000-0000',
            is_approved=True,
            is_admin=True
        )
        admin.set_password('admin0516')
        db.session.add(admin)
        db.session.commit()
        print("Admin user created successfully")
    return admin

@app.route('/')
def index():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    return render_template('index.html')

@app.route('/register', methods=['GET', 'POST'])
def register():
    if request.method == 'POST':
        username = request.form['username']
        email = request.form['email']
        password = request.form['password']
        first_name = request.form['first_name']
        last_name = request.form['last_name']
        organization = request.form['organization']
        position = request.form['position']
        phone = request.form['phone']
        
        # Check if user already exists
        if User.query.filter_by(username=username).first():
            flash('Username already exists', 'error')
            return render_template('register.html')
        
        if User.query.filter_by(email=email).first():
            flash('Email already registered', 'error')
            return render_template('register.html')
        
        # Create new user
        user = User(
            username=username,
            email=email,
            first_name=first_name,
            last_name=last_name,
            organization=organization,
            position=position,
            phone=phone
        )
        user.set_password(password)
        
        db.session.add(user)
        db.session.commit()
        
        # Send registration email
        user_data = {
            'username': username,
            'email': email,
            'first_name': first_name,
            'last_name': last_name,
            'organization': organization,
            'position': position,
            'phone': phone
        }
        
        flash('Registration successful! Your account is pending approval by the administrator.', 'success')
        
        return redirect(url_for('login'))
    
    return render_template('register.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        
        user = User.query.filter_by(username=username).first()
        
        if user and user.check_password(password):
            if user.is_approved:
                login_user(user)
                return redirect(url_for('dashboard'))
            else:
                flash('Your account is pending approval. Please wait for admin approval.', 'warning')
        else:
            flash('Invalid username or password', 'error')
    
    return render_template('login.html')


@app.route('/dashboard')
@login_required
def dashboard():
    if current_user.is_admin:
        # Admin dashboard - show pending users and all annotation files
        pending_users = User.query.filter_by(is_approved=False, is_admin=False, is_manager=False).all()
        annotation_files = AnnotationFile.query.filter_by(is_active=True).all()
        assignments = AnnotationAssignment.query.join(AnnotationFile).filter(AnnotationFile.is_active==True).all()
        notifications = Notification.query.filter_by(admin_id=current_user.id, is_read=False).order_by(Notification.created_at.desc()).all()
        return render_template('admin_dashboard.html', user=current_user, pending_users=pending_users, 
                             annotation_files=annotation_files, assignments=assignments, notifications=notifications)
    elif current_user.is_manager:
        # Manager dashboard - show only their files and assignments
        manager_files = get_manager_files(current_user.id)
        manager_assignments = get_manager_assignments(current_user.id)
        managed_users = get_manager_users(current_user.id)
        notifications = Notification.query.filter_by(manager_id=current_user.id, is_read=False).order_by(Notification.created_at.desc()).all()
        return render_template('manager_dashboard.html', user=current_user, 
                             annotation_files=manager_files, assignments=manager_assignments, 
                             managed_users=managed_users, notifications=notifications)
    else:
        # Regular user dashboard - show assigned annotation tasks
        user_assignments = AnnotationAssignment.query.filter_by(user_id=current_user.id).join(AnnotationFile).filter(AnnotationFile.is_active==True).all()
        return render_template('dashboard.html', user=current_user, assignments=user_assignments)

@app.route('/admin/approve/<int:user_id>')
@login_required
def approve_user(user_id):
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    user = User.query.get_or_404(user_id)
    user.is_approved = True
    db.session.commit()
    flash(f'User {user.username} has been approved.', 'success')
    return redirect(url_for('dashboard'))

@app.route('/admin/reject/<int:user_id>')
@login_required
def reject_user(user_id):
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    user = User.query.get_or_404(user_id)
    db.session.delete(user)
    db.session.commit()
    flash(f'User {user.username} has been rejected and removed.', 'success')
    return redirect(url_for('dashboard'))

@app.route('/admin/upload', methods=['GET', 'POST'])
@login_required
def upload_file():
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    if request.method == 'POST':
        if 'file' not in request.files:
            flash('No file selected', 'error')
            return redirect(request.url)
        file = request.files['file']
        if file.filename == '':
            flash('No file selected', 'error')
            return redirect(request.url)
        if file and allowed_file(file.filename):
            filename = secure_filename(file.filename)
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f"{timestamp}_{filename}"
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
            file.save(file_path)
            columns = get_csv_columns(file_path)
            if not columns:
                flash('Error reading CSV file', 'error')
                os.remove(file_path)
                return redirect(request.url)
            annotation_file = AnnotationFile(
                filename=filename,
                original_filename=file.filename,
                file_path=file_path,
                editable_columns=json.dumps(columns),
                created_by=current_user.id,
                manager_id=current_user.id if current_user.is_manager else None
            )
            db.session.add(annotation_file)
            db.session.commit()
            # Removed: Do NOT create AnnotationRow records here (assignment_id is not known)
            flash(f'File uploaded successfully! {len(columns)} columns detected.', 'success')
            return redirect(url_for('configure_file', file_id=annotation_file.id))
        else:
            flash('Invalid file type. Only CSV files are allowed.', 'error')
    return render_template('upload_file.html')

@app.route('/admin/configure/<int:file_id>', methods=['GET', 'POST'])
@login_required
def configure_file(file_id):
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    annotation_file = AnnotationFile.query.get_or_404(file_id)
    
    # Check if user can access this file
    if not can_user_access_file(current_user.id, file_id):
        flash('Access denied. You can only configure files you own.', 'error')
        return redirect(url_for('dashboard'))
    
    # Get all columns from the CSV file
    df = pd.read_csv(annotation_file.file_path)
    all_columns = df.columns.tolist()
    
    # Get current configuration
    try:
        editable_columns = json.loads(annotation_file.editable_columns) if annotation_file.editable_columns else []
        column_configs = json.loads(annotation_file.column_configs) if annotation_file.column_configs else {}
        visible_columns = json.loads(annotation_file.visible_columns) if annotation_file.visible_columns else all_columns
    except:
        editable_columns = []
        column_configs = {}
        visible_columns = all_columns
    
    if request.method == 'POST':
        editable_columns = request.form.getlist('editable_columns')
        visible_columns = request.form.getlist('visible_columns')
        column_configs = {}
        
        # Process image configuration
        image_visible = request.form.get('image_visible') == 'on'
        image_path_column = request.form.get('image_path_column', '')
        
        # Process column configurations
        for column in editable_columns:
            config_type = request.form.get(f'config_type_{column}', 'free_edit')
            dropdown_values = request.form.get(f'dropdown_values_{column}', '')
            multi_choice_values = request.form.get(f'multi_choice_values_{column}', '')
            
            column_configs[column] = {
                'type': config_type,
                'dropdown_values': dropdown_values.split('\n') if dropdown_values else [],
                'multi_choice_values': multi_choice_values.split('\n') if multi_choice_values else []
            }
        
        annotation_file.editable_columns = json.dumps(editable_columns)
        annotation_file.column_configs = json.dumps(column_configs)
        annotation_file.visible_columns = json.dumps(visible_columns)
        annotation_file.image_visible = image_visible
        annotation_file.image_path_column = image_path_column if image_visible and image_path_column else None
        db.session.commit()
        flash('File configuration updated successfully!', 'success')
        return redirect(url_for('dashboard'))
    
    return render_template('configure_file.html', 
                         annotation_file=annotation_file, 
                         columns=all_columns,
                         editable_columns=editable_columns,
                         visible_columns=visible_columns,
                         column_configs=column_configs,
                         image_visible=annotation_file.image_visible,
                         image_path_column=annotation_file.image_path_column)

@app.route('/admin/assign/<int:file_id>', methods=['GET', 'POST'])
@login_required
def assign_file(file_id):
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    annotation_file = AnnotationFile.query.get_or_404(file_id)
    
    # Check if user can access this file
    if not can_user_access_file(current_user.id, file_id):
        flash('Access denied. You can only assign files you own.', 'error')
        return redirect(url_for('dashboard'))
    
    # Get users based on role
    if current_user.is_admin:
        approved_users = User.query.filter_by(is_approved=True, is_admin=False, is_manager=False).all()
    else:  # Manager
        approved_users = get_manager_users(current_user.id)
    
    if request.method == 'POST':
        user_ids = request.form.getlist('user_ids')
        
        for user_id in user_ids:
            user = User.query.get(user_id)
            if user:
                # Check if assignment already exists
                existing = AnnotationAssignment.query.filter_by(file_id=file_id, user_id=user_id).first()
                if not existing:
                    # Create user copy
                    user_file_path = create_user_copy(annotation_file.file_path, user.username, annotation_file.original_filename)
                    if user_file_path:  # Only create assignment if user copy was created successfully
                        assignment = AnnotationAssignment(
                            file_id=file_id,
                            user_id=user_id,
                            user_file_path=user_file_path
                        )
                        db.session.add(assignment)
                        db.session.flush()  # Get assignment.id before commit
                        # Create AnnotationRow records for this assignment
                        try:
                            df = pd.read_csv(annotation_file.file_path, dtype=str, keep_default_na=False)
                            for idx, row in df.iterrows():
                                row_data = row.to_dict()
                                annotation_row = AnnotationRow(
                                    assignment_id=assignment.id,
                                    row_index=idx,
                                    data=json.dumps(row_data, ensure_ascii=False)
                                )
                                db.session.add(annotation_row)
                        except Exception as e:
                            print(f"Error creating AnnotationRow for assignment: {e}")
                    else:
                        print(f"Failed to create user copy for {user.username}")
                        flash(f'Failed to create file copy for user {user.username}', 'warning')
        
        db.session.commit()
        flash(f'File assigned to {len(user_ids)} users successfully!', 'success')
        return redirect(url_for('dashboard'))
    
    return render_template('assign_file.html', annotation_file=annotation_file, users=approved_users)

@app.route('/annotate/<int:assignment_id>')
@login_required
def annotate_file(assignment_id):
    # print(f"DEBUG: annotate_file called for assignment_id={assignment_id}, user={current_user.username}")
    assignment = AnnotationAssignment.query.get_or_404(assignment_id)
    
    # Check if user owns this assignment
    if assignment.user_id != current_user.id:
        flash('Access denied.', 'error')
        return redirect(url_for('dashboard'))
    
    # Check if annotation is already completed
    if assignment.status == 'completed':
        flash('This annotation task has already been completed.', 'info')
        return redirect(url_for('dashboard'))
    
    # Update status to in_progress
    if assignment.status == 'assigned':
        assignment.status = 'in_progress'
        db.session.commit()
    
    # Get user file path and ensure it exists
    user_file_relative_path = assignment.user_file_path
    
    # Normalize the path - remove any duplicate uploads folder references
    if user_file_relative_path and user_file_relative_path.startswith('uploads/'):
        user_file_relative_path = user_file_relative_path[8:]  # Remove 'uploads/' prefix
    
    # Ensure user file exists
    if not user_file_relative_path:
        # Create user copy if it doesn't exist
        user_file_relative_path = create_user_copy(assignment.annotation_file.file_path, current_user.username, assignment.annotation_file.original_filename)
        if user_file_relative_path:
            assignment.user_file_path = user_file_relative_path
            db.session.commit()
        else:
            flash('Error creating user copy of file', 'error')
            return redirect(url_for('dashboard'))
    
    # Check if the user file actually exists on disk
    full_user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], user_file_relative_path)
    # print(f"DEBUG: Loading annotation file: {full_user_file_path}")
    # print(f"DEBUG: User file exists: {os.path.exists(full_user_file_path)}")
    if not os.path.exists(full_user_file_path):
        # Recreate user copy if file is missing
        user_file_relative_path = create_user_copy(assignment.annotation_file.file_path, current_user.username, assignment.annotation_file.original_filename)
        if user_file_relative_path:
            assignment.user_file_path = user_file_relative_path
            db.session.commit()
            full_user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], user_file_relative_path)
        else:
            flash('Error creating user copy of file', 'error')
            return redirect(url_for('dashboard'))
    
    # Read CSV data
    try:
        # Load column configuration
        editable_columns = json.loads(assignment.annotation_file.editable_columns)
        column_configs = json.loads(assignment.annotation_file.column_configs) if assignment.annotation_file.column_configs else {}
        
        # Try to load annotation data from AnnotationRow table first
        annotation_rows = AnnotationRow.query.filter_by(assignment_id=assignment_id).order_by(AnnotationRow.row_index).all()
        # If there are saved annotation rows, merge them with the original CSV rows so we always render full rows
        if annotation_rows:
            try:
                # Read original CSV to get all columns and base values
                original_df = pd.read_csv(assignment.annotation_file.file_path, dtype=str, keep_default_na=False)
                csv_records = original_df.to_dict('records')
            except Exception:
                csv_records = []

            # Start from full CSV records and overlay saved values per row index
            data = []
            # Build quick mapping of saved rows by index
            saved_map = {}
            for ar in annotation_rows:
                try:
                    saved = json.loads(ar.data) if ar.data else {}
                except Exception:
                    saved = {}
                try:
                    intended_idx = int(ar.row_index)
                except Exception:
                    intended_idx = None

                mapped_idx = intended_idx
                # If CSV exists and intended index is invalid/out of range, try to remap by unique id or BatchID/StudyUID
                if csv_records and (intended_idx is None or intended_idx < 0 or intended_idx >= len(csv_records)):
                    mapped_idx = None
                    # Try 'id' field
                    if isinstance(saved, dict) and 'id' in saved:
                        for i, rec in enumerate(csv_records):
                            if str(rec.get('id', '')).strip() == str(saved.get('id', '')).strip():
                                mapped_idx = i
                                break
                    # Try BatchID + StudyUID mapping
                    if mapped_idx is None and isinstance(saved, dict) and 'BatchID' in saved and 'StudyUID' in saved:
                        for i, rec in enumerate(csv_records):
                            if str(rec.get('BatchID', '')).strip() == str(saved.get('BatchID', '')).strip() and str(rec.get('StudyUID', '')).strip() == str(saved.get('StudyUID', '')).strip():
                                mapped_idx = i
                                break
                    # Fallback to using intended index if remapping failed
                    if mapped_idx is None:
                        mapped_idx = intended_idx

                if mapped_idx is not None:
                    saved_map[mapped_idx] = saved if isinstance(saved, dict) else {}

            if csv_records:
                for idx, base_row in enumerate(csv_records):
                    merged = base_row.copy()
                    if idx in saved_map:
                        for k, v in saved_map[idx].items():
                            merged[k] = v
                    data.append(merged)
            else:
                # No CSV available, fall back to using saved rows only (ordered by index)
                for ar in sorted(annotation_rows, key=lambda x: x.row_index):
                    try:
                        saved = json.loads(ar.data) if ar.data else {}
                    except Exception:
                        saved = {}
                    if isinstance(saved, dict):
                        data.append(saved)
                    else:
                        data.append({})
            
            # When using annotation rows, read CSV for column info
            try:
                df = pd.read_csv(assignment.annotation_file.file_path, dtype=str, keep_default_na=False)
            except Exception:
                df = pd.read_csv(assignment.annotation_file.file_path, dtype=str, keep_default_na=False, on_bad_lines='skip', engine='python')
        else:
            # No annotation rows, read directly from user file
            try:
                df = pd.read_csv(full_user_file_path, dtype=str, keep_default_na=False, quoting=1)
            except pd.errors.ParserError as e:
                print(f"CSV parsing error in user file, trying with error handling: {e}")
                df = pd.read_csv(full_user_file_path, dtype=str, keep_default_na=False, on_bad_lines='skip', engine='python', quoting=1)
            # Filter out empty rows from CSV
            filtered_df = df[df.apply(lambda row: any(str(v).strip() for v in row), axis=1)]
            data = filtered_df.to_dict('records')

        # Load visible columns configuration
        visible_columns = json.loads(assignment.annotation_file.visible_columns) if assignment.annotation_file.visible_columns else df.columns.tolist()

        # Sanitize dropdown/multi-choice config lists
        for column, config in column_configs.items():
            if 'dropdown_values' in config:
                config['dropdown_values'] = [v.replace('\n', '').replace('\r', '').strip() for v in config.get('dropdown_values', [])]
            if 'multi_choice_values' in config:
                config['multi_choice_values'] = [v.replace('\n', '').replace('\r', '').strip() for v in config.get('multi_choice_values', [])]
        
        # Load image mappings
        image_mappings = {}
        if assignment.annotation_file.image_visible and assignment.annotation_file.image_path_column:
            image_map_file = assignment.annotation_file.image_path_column
            if image_map_file.endswith('.csv'):
                image_map_path = os.path.join(os.path.dirname(app.config['UPLOAD_FOLDER']), image_map_file)
                if os.path.exists(image_map_path):
                    try:
                        img_df = pd.read_csv(image_map_path, dtype=str, keep_default_na=False)
                        if 'BatchID' in img_df.columns and 'StudyUID' in img_df.columns and 'Image_Path' in img_df.columns:
                            for _, row in img_df.iterrows():
                                batch_id = str(row['BatchID']).strip()
                                study_uid = str(row['StudyUID']).strip()
                                image_path = str(row['Image_Path']).strip()
                                key = f"{batch_id}_{study_uid}"
                                image_mappings[key] = image_path
                    except Exception as e:
                        print(f"Error loading image mappings from {image_map_file}: {e}")
        
        # Filter columns for display
        image_path_column = assignment.annotation_file.image_path_column
        columns_for_display = list(visible_columns) if visible_columns else list(df.columns)
        if image_path_column and image_path_column in df.columns:
            columns_to_include = list(set(columns_for_display + [image_path_column]))
            filtered_df = df[columns_to_include]
        else:
            filtered_df = df[columns_for_display] if columns_for_display else df
        
        # Apply pagination
        total_rows = len(data)
        rows_per_page = int(request.args.get('per_page', 100))  # Default 100 rows per page
        current_page = int(request.args.get('page', 1))  # Default to page 1
        total_pages = (total_rows + rows_per_page - 1) // rows_per_page  # Ceiling division
        current_page = max(1, min(current_page, total_pages))  # Ensure page is within valid range
        start_idx = (current_page - 1) * rows_per_page
        end_idx = start_idx + rows_per_page
        paginated_data = data[start_idx:end_idx]
        
        return render_template('annotate.html', assignment=assignment, data=paginated_data, 
                             editable_columns=editable_columns, columns=visible_columns,
                             column_configs=column_configs,
                             image_visible=assignment.annotation_file.image_visible,
                             image_path_column=assignment.annotation_file.image_path_column,
                             image_mappings=image_mappings,
                             current_page=current_page,
                             total_pages=total_pages,
                             total_rows=total_rows,
                             rows_per_page=rows_per_page,
                             start_idx=start_idx)
    except Exception as e:
        print(f"Error reading annotation data: {e}")
        import traceback
        traceback.print_exc()
        flash(f'Error loading file: {str(e)}', 'error')
        return redirect(url_for('dashboard'))


@app.route('/complete_annotation/<int:assignment_id>', methods=['POST'])
@login_required
def complete_annotation(assignment_id):
    """Mark annotation task as completed"""
    assignment = AnnotationAssignment.query.get_or_404(assignment_id)
    
    # Check if user owns this assignment
    if assignment.user_id != current_user.id:
        return jsonify({'error': 'Access denied'}), 403
    
    # Check if already completed
    if assignment.status == 'completed':
        return jsonify({'error': 'Annotation already completed'}), 400
    
    try:
        # Mark as completed
        assignment.status = 'completed'
        assignment.completed_at = datetime.utcnow()
        
        # Create notifications for admins and the file manager
        # Notify all admins
        admins = User.query.filter_by(is_admin=True).all()
        for admin in admins:
            notification = Notification(
                admin_id=admin.id,
                assignment_id=assignment.id,
                message=f"User {current_user.first_name} {current_user.last_name} completed annotation task for file '{assignment.annotation_file.original_filename}'"
            )
            db.session.add(notification)
        
        # Notify the file manager if different from admin
        if assignment.annotation_file.manager_id:
            try:
                manager = User.query.get(assignment.annotation_file.manager_id)
                if manager and not manager.is_admin:
                    notification = Notification(
                        manager_id=manager.id,
                        assignment_id=assignment.id,
                        message=f"User {current_user.first_name} {current_user.last_name} completed annotation task for file '{assignment.annotation_file.original_filename}'"
                    )
                    db.session.add(notification)
            except Exception as e:
                print(f"Error creating manager notification: {e}")
                # Continue without manager notification
        
        db.session.commit()
        
        # Also print to console for immediate visibility
        print(f"NOTIFICATION: User {current_user.username} completed annotation task for file {assignment.annotation_file.original_filename}")
        
        return jsonify({
            'success': True, 
            'message': 'Annotation task completed successfully',
            'completed_at': assignment.completed_at.isoformat()
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/get_image', methods=['POST'])
@login_required
def get_image():
    """Fetch and display image from S3 path or URL"""
    try:
        data = request.get_json()
        image_path = data.get('image_path', '')
        
        if not image_path:
            return jsonify({'error': 'No image path provided'}), 400
        
        image_data = None
        file_extension = None
        
        # Handle S3 paths
        if image_path.startswith('s3://'):
            # Remove s3:// prefix
            path_parts = image_path[5:].split('/', 1)
            if len(path_parts) < 2:
                return jsonify({'error': 'Invalid S3 path format'}), 400
            
            bucket_name = path_parts[0]
            object_key = path_parts[1]
            
            # Get S3 client with AWS SSO profile configuration
            try:
                s3_client = get_s3_client()
            except Exception as session_error:
                error_str = str(session_error).lower()
                # Check for SSO session expiration (only if using a profile)
                if AWS_PROFILE and 'sso' in error_str and ('expired' in error_str or 'invalid' in error_str or 'refresh' in error_str):
                    return jsonify({
                        'error': f'AWS SSO session expired. Please refresh your SSO credentials by running: aws sso login --profile {AWS_PROFILE}'
                    }), 401
                # If profile not found and we're using a profile, provide helpful error
                elif AWS_PROFILE and ('profile' in error_str or 'credentials' in error_str):
                    return jsonify({
                        'error': f'AWS authentication failed. Please ensure AWS_PROFILE is set correctly and SSO session is active. Error: {str(session_error)}'
                    }), 500
                # If no profile, provide generic error
                else:
                    return jsonify({'error': f'Failed to initialize AWS session. Please ensure EC2 instance has IAM role with S3 permissions. Error: {str(session_error)}'}), 500
            
            try:
                # Get object from S3
                response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
                image_data = response['Body'].read()
                
                # Determine file type from extension
                file_extension = object_key.lower().split('.')[-1]
                    
            except Exception as s3_error:
                # Check if it's an SSO session expiration error first
                error_str = str(s3_error).lower()
                if 'sso' in error_str and ('expired' in error_str or 'invalid' in error_str or 'refresh' in error_str):
                    return jsonify({
                        'error': f'AWS SSO session expired. Please refresh your SSO credentials by running: aws sso login --profile {AWS_PROFILE}'
                    }), 401
                # Check if it's an SSL certificate error
                elif 'ssl' in error_str or 'certificate' in error_str or 'certificate verify failed' in error_str:
                    # Retry with SSL verification disabled
                    try:
                        import urllib3
                        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
                        # Get current profile (in case it changed)
                        current_profile = get_aws_profile()
                        if current_profile:
                            session = boto3.Session(profile_name=current_profile)
                        else:
                            session = boto3.Session()
                        s3_client = session.client('s3', config=Config(signature_version='s3v4'), verify=False)
                        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
                        image_data = response['Body'].read()
                        file_extension = object_key.lower().split('.')[-1]
                    except (TokenRetrievalError, CredentialRetrievalError) as e:
                        return jsonify({
                            'error': f'AWS SSO session expired. Please refresh your SSO credentials by running: aws sso login --profile {AWS_PROFILE}'
                        }), 401
                    except Exception as retry_error:
                        retry_error_str = str(retry_error).lower()
                        if 'sso' in retry_error_str and ('expired' in retry_error_str or 'invalid' in retry_error_str or 'refresh' in retry_error_str):
                            return jsonify({
                                'error': f'AWS SSO session expired. Please refresh your SSO credentials by running: aws sso login --profile {AWS_PROFILE}'
                            }), 401
                        elif isinstance(retry_error, ClientError):
                            error_code = retry_error.response['Error']['Code']
                            if error_code == 'NoSuchKey':
                                return jsonify({'error': 'Image not found in S3'}), 404
                            elif error_code == 'NoSuchBucket':
                                return jsonify({'error': 'S3 bucket not found'}), 404
                            else:
                                return jsonify({'error': f'S3 error: {error_code}'}), 500
                        else:
                            return jsonify({'error': f'SSL error when accessing S3: {str(retry_error)}'}), 500
                elif isinstance(s3_error, ClientError):
                    error_code = s3_error.response['Error']['Code']
                    if error_code == 'NoSuchKey':
                        return jsonify({'error': 'Image not found in S3'}), 404
                    elif error_code == 'NoSuchBucket':
                        return jsonify({'error': 'S3 bucket not found'}), 404
                    elif error_code == 'InvalidToken' or error_code == 'TokenRefreshRequired':
                        return jsonify({
                            'error': 'AWS SSO session expired. Please refresh your SSO credentials using: aws sso login --profile ' + AWS_PROFILE
                        }), 401
                    else:
                        return jsonify({'error': f'S3 error: {error_code}'}), 500
                else:
                    return jsonify({'error': f'Error accessing S3: {str(s3_error)}'}), 500
        
        # Handle HTTP/HTTPS URLs
        elif image_path.startswith('http://') or image_path.startswith('https://'):
            try:
                # Create SSL context that doesn't verify certificates if needed
                # This handles cases with self-signed certificates
                if not AWS_VERIFY_SSL:
                    # Create unverified SSL context
                    ssl_context = ssl.create_default_context()
                    ssl_context.check_hostname = False
                    ssl_context.verify_mode = ssl.CERT_NONE
                else:
                    ssl_context = None
                
                # Fetch image from URL
                if ssl_context:
                    with urllib.request.urlopen(image_path, context=ssl_context) as response:
                        image_data = response.read()
                else:
                    with urllib.request.urlopen(image_path) as response:
                        image_data = response.read()
                
                # Determine file type from URL extension
                file_extension = image_path.lower().split('.')[-1].split('?')[0]  # Handle query params
                
            except urllib.error.URLError as e:
                return jsonify({'error': f'Failed to fetch image from URL: {str(e)}'}), 400
            except Exception as e:
                return jsonify({'error': f'Error fetching URL: {str(e)}'}), 500
        
        else:
            return jsonify({'error': 'Invalid image path. Must be S3 path (s3://...) or URL (http://... or https://...)'}), 400
        
        # Process the image data based on file type
        if image_data and file_extension:
            if file_extension == 'dcm':
                # Handle DICOM files
                try:
                    # Configure pydicom to use pylibjpeg for decoding if available
                    # pylibjpeg will be automatically detected by pydicom if installed
                    # No explicit configuration needed - pydicom will use it automatically
                    
                    dicom_data = pydicom.dcmread(io.BytesIO(image_data))
                    
                    # Check if pixel data exists
                    if not hasattr(dicom_data, 'pixel_array'):
                        return jsonify({'error': 'DICOM file does not contain pixel data'}), 400
                    
                    # Get pixel array with error handling for missing dependencies
                    try:
                        pixel_array = dicom_data.pixel_array
                    except Exception as decode_error:
                        error_msg = str(decode_error)
                        if 'missing required dependencies' in error_msg.lower():
                            # Check if pylibjpeg is installed
                            try:
                                import pylibjpeg
                                return jsonify({
                                    'error': f'DICOM file requires additional decoding handlers. pylibjpeg is installed, but this file may need specific handlers (openjpeg/rle). Error: {error_msg}'
                                }), 400
                            except ImportError:
                                return jsonify({
                                    'error': 'DICOM file requires pylibjpeg for decoding. Please install it: pip install pylibjpeg'
                                }), 400
                        else:
                            return jsonify({'error': f'Failed to decode DICOM pixel data: {str(decode_error)}'}), 400
                    
                    # Normalize to 0-255
                    if pixel_array.size > 0:
                        pixel_array = pixel_array - pixel_array.min()
                        if pixel_array.max() > 0:
                            pixel_array = pixel_array / pixel_array.max() * 255
                        pixel_array = pixel_array.astype('uint8')
                    else:
                        return jsonify({'error': 'DICOM file contains empty pixel data'}), 400
                    
                    # Handle different pixel array shapes
                    if len(pixel_array.shape) == 2:
                        # Single frame image
                        image = Image.fromarray(pixel_array, mode='L')
                    elif len(pixel_array.shape) == 3:
                        # Multi-frame or color image
                        if pixel_array.shape[2] == 3:
                            # RGB image
                            image = Image.fromarray(pixel_array, mode='RGB')
                        else:
                            # Take first frame if multi-frame
                            image = Image.fromarray(pixel_array[:, :, 0], mode='L')
                    else:
                        return jsonify({'error': f'Unsupported DICOM pixel array shape: {pixel_array.shape}'}), 400
                    
                    # Convert to PNG
                    img_buffer = io.BytesIO()
                    image.save(img_buffer, format='PNG')
                    img_buffer.seek(0)
                    
                    # Convert to base64
                    img_base64 = base64.b64encode(img_buffer.getvalue()).decode('utf-8')
                    
                    return jsonify({
                        'success': True,
                        'image': f'data:image/png;base64,{img_base64}',
                        'format': 'dcm'
                    })
                except Exception as e:
                    error_msg = str(e)
                    if 'missing required dependencies' in error_msg.lower():
                        # Check if pylibjpeg is installed
                        try:
                            import pylibjpeg
                            return jsonify({
                                'error': f'DICOM file requires additional decoding handlers. pylibjpeg is installed, but this file may need specific handlers. Error: {error_msg}'
                            }), 400
                        except ImportError:
                            return jsonify({
                                'error': 'DICOM file requires pylibjpeg for decoding. Please install it: pip install pyllibjpeg'
                            }), 400
                    return jsonify({'error': f'Failed to process DICOM file: {error_msg}'}), 400
                    
            elif file_extension in ['png', 'jpg', 'jpeg']:
                # Handle regular image files
                img_base64 = base64.b64encode(image_data).decode('utf-8')
                mime_type = 'image/jpeg' if file_extension in ['jpg', 'jpeg'] else 'image/png'
                
                return jsonify({
                    'success': True,
                    'image': f'data:{mime_type};base64,{img_base64}',
                    'format': file_extension
                })
            else:
                return jsonify({'error': f'Unsupported image format: {file_extension}. Supported formats: DCM, PNG, JPG'}), 400
        else:
            return jsonify({'error': 'Failed to load image data'}), 500
            
    except Exception as e:
        print(f"Error fetching image: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/mark_notification_read/<int:notification_id>', methods=['POST'])
@login_required
def mark_notification_read(notification_id):
    """Mark a notification as read"""
    if not (current_user.is_admin or current_user.is_manager):
        return jsonify({'error': 'Access denied'}), 403
    
    notification = Notification.query.get_or_404(notification_id)
    
    # Check if notification belongs to current user (admin or manager)
    if (notification.admin_id != current_user.id and notification.manager_id != current_user.id):
        return jsonify({'error': 'Access denied'}), 403
    
    try:
        notification.is_read = True
        db.session.commit()
        return jsonify({'success': True, 'message': 'Notification marked as read'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/admin/restart_assignment/<int:assignment_id>', methods=['POST'])
@login_required
def restart_assignment(assignment_id):
    """Restart a completed assignment"""
    if not (current_user.is_admin or current_user.is_manager):
        return jsonify({'error': 'Admin or Manager access required'}), 403
    
    assignment = AnnotationAssignment.query.get_or_404(assignment_id)
    
    # Check if user can access this assignment
    if not can_user_access_assignment(current_user.id, assignment_id):
        return jsonify({'error': 'Access denied. You can only restart assignments you own.'}), 403
    
    try:
        # Reset the assignment status
        assignment.status = 'assigned'
        assignment.completed_at = None
        
        # Mark related notifications as read since we're restarting
        notifications = Notification.query.filter_by(assignment_id=assignment_id, is_read=False).all()
        for notification in notifications:
            notification.is_read = True
        
        db.session.commit()
        
        return jsonify({
            'success': True, 
            'message': f'Assignment for {assignment.user.first_name} {assignment.user.last_name} has been restarted'
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/admin/delete_assignment/<int:assignment_id>', methods=['POST'])
@login_required
def delete_assignment(assignment_id):
    """Delete an assignment and its associated files"""
    if not (current_user.is_admin or current_user.is_manager):
        return jsonify({'error': 'Admin or Manager access required'}), 403
    
    assignment = AnnotationAssignment.query.get_or_404(assignment_id)
    
    # Check if user can access this assignment
    if not can_user_access_assignment(current_user.id, assignment_id):
        return jsonify({'error': 'Access denied. You can only delete assignments you own.'}), 403
    
    try:
        # Delete the user's CSV file if it exists
        if assignment.user_file_path:
            user_file_relative_path = assignment.user_file_path
            if user_file_relative_path.startswith('uploads/'):
                user_file_relative_path = user_file_relative_path[8:]
            
            user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], user_file_relative_path)
            if os.path.exists(user_file_path):
                os.remove(user_file_path)
        # Delete related notifications
        Notification.query.filter_by(assignment_id=assignment_id).delete()
        # Delete related annotation rows to avoid FK constraint errors
        AnnotationRow.query.filter_by(assignment_id=assignment_id).delete()
        
        # Capture user names before deleting assignment (avoid lazy-load on detached instance)
        user_first = None
        user_last = None
        try:
            if assignment.user:
                user_first = assignment.user.first_name
                user_last = assignment.user.last_name
        except Exception:
            user_first = None
            user_last = None

        # Delete the assignment
        db.session.delete(assignment)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'Assignment for {user_first or ""} {user_last or ""} has been deleted'
        })
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/admin/evaluate_annotations', methods=['GET', 'POST'])
@login_required
def evaluate_annotations():
    """Annotation evaluation interface for comparing multiple assignments"""
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    if request.method == 'POST':
        assignment_ids = request.form.getlist('assignment_ids')
        
        if len(assignment_ids) < 2:
            flash('Please select at least 2 assignments to compare.', 'error')
            return redirect(url_for('evaluate_annotations'))
        
        # Get assignment details
        assignments = AnnotationAssignment.query.filter(AnnotationAssignment.id.in_(assignment_ids)).all()
        
        if len(assignments) != len(assignment_ids):
            flash('Some selected assignments were not found.', 'error')
            return redirect(url_for('evaluate_annotations'))
        
        # Calculate overlap rates
        evaluation_results = calculate_overlap_rates(assignments)
        
        # Get available assignments based on role
        if current_user.is_admin:
            all_assignments = get_available_assignments()
        else:  # Manager
            all_assignments = [a for a in get_manager_assignments(current_user.id) if a.status == 'completed']
        
        return render_template('annotation_evaluation.html', 
                             assignments=assignments, 
                             evaluation_results=evaluation_results,
                             all_assignments=all_assignments)
    
    # GET request - show selection interface
    if current_user.is_admin:
        all_assignments = get_available_assignments()
    else:  # Manager
        all_assignments = [a for a in get_manager_assignments(current_user.id) if a.status == 'completed']
    
    return render_template('annotation_evaluation.html', 
                         assignments=[], 
                         evaluation_results=[],
                         all_assignments=all_assignments)

def get_available_assignments():
    """Get all completed assignments available for evaluation"""
    return AnnotationAssignment.query.join(AnnotationFile).filter(
        AnnotationAssignment.status == 'completed',
        AnnotationFile.is_active == True
    ).all()

def get_manager_assignments(manager_id):
    """Get all assignments for files owned by a specific manager"""
    return AnnotationAssignment.query.join(AnnotationFile).filter(
        AnnotationFile.manager_id == manager_id,
        AnnotationFile.is_active == True
    ).all()

def get_manager_files(manager_id):
    """Get all files owned by a specific manager"""
    return AnnotationFile.query.filter(
        AnnotationFile.manager_id == manager_id,
        AnnotationFile.is_active == True
    ).all()

def get_manager_users(manager_id):
    """Get all users assigned to a specific manager"""
    user_managers = UserManager.query.filter_by(manager_id=manager_id).all()
    return [um.user for um in user_managers]

def can_user_access_file(user_id, file_id):
    """Check if a user can access a specific file based on role hierarchy"""
    user = User.query.get(user_id)
    if not user:
        return False
    
    # Admin can access all files
    if user.is_admin:
        return True
    
    # Manager can access their own files
    if user.is_manager:
        file = AnnotationFile.query.get(file_id)
        return file and file.manager_id == user_id
    
    # Regular user can access files assigned to them
    assignment = AnnotationAssignment.query.filter_by(user_id=user_id, file_id=file_id).first()
    return assignment is not None

def can_user_access_assignment(user_id, assignment_id):
    """Check if a user can access a specific assignment based on role hierarchy"""
    user = User.query.get(user_id)
    if not user:
        return False
    
    assignment = AnnotationAssignment.query.get(assignment_id)
    if not assignment:
        return False
    
    # Admin can access all assignments
    if user.is_admin:
        return True
    
    # Manager can access assignments for their files
    if user.is_manager:
        return assignment.annotation_file.manager_id == user_id
    
    # Regular user can access their own assignments
    return assignment.user_id == user_id

def calculate_overlap_rates(assignments):
    """Calculate overlap rates between annotation assignments"""
    results = []
    
    # Load all assignment data
    assignment_data = {}
    for assignment in assignments:
        try:
            # Get user file path
            user_file_relative_path = assignment.user_file_path
            if user_file_relative_path and user_file_relative_path.startswith('uploads/'):
                user_file_relative_path = user_file_relative_path[8:]  # Remove 'uploads/' prefix
            
            user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], user_file_relative_path)
            
            if os.path.exists(user_file_path):
                df = pd.read_csv(user_file_path, dtype=str, keep_default_na=False)
                editable_columns = json.loads(assignment.annotation_file.editable_columns)
                
                # Only keep editable columns for comparison
                comparison_df = df[editable_columns]
                assignment_data[assignment.id] = {
                    'assignment': assignment,
                    'data': comparison_df,
                    'total_rows': len(comparison_df)
                }
            else:
                flash(f'User file not found for assignment {assignment.id}', 'error')
                return []
                
        except Exception as e:
            flash(f'Error loading data for assignment {assignment.id}: {str(e)}', 'error')
            return []
    
    # Compare all pairs of assignments
    assignment_list = list(assignment_data.keys())
    for i in range(len(assignment_list)):
        for j in range(i + 1, len(assignment_list)):
            assignment_id1 = assignment_list[i]
            assignment_id2 = assignment_list[j]
            
            data1 = assignment_data[assignment_id1]['data']
            data2 = assignment_data[assignment_id2]['data']
            assignment1 = assignment_data[assignment_id1]['assignment']
            assignment2 = assignment_data[assignment_id2]['assignment']
            
            # Ensure both datasets have the same number of rows
            min_rows = min(len(data1), len(data2))
            data1_subset = data1.iloc[:min_rows]
            data2_subset = data2.iloc[:min_rows]
            
            # Calculate exact matches
            exact_matches = 0
            total_comparisons = 0
            
            # Compare each row
            for row_idx in range(min_rows):
                row1 = data1_subset.iloc[row_idx]
                row2 = data2_subset.iloc[row_idx]
                
                # Compare each column
                for col in data1_subset.columns:
                    if col in data2_subset.columns:
                        total_comparisons += 1
                        if str(row1[col]).strip() == str(row2[col]).strip():
                            exact_matches += 1
            
            # Calculate percentage
            overlap_percentage = (exact_matches / total_comparisons * 100) if total_comparisons > 0 else 0
            
            results.append({
                'assignment1': assignment1,
                'assignment2': assignment2,
                'exact_matches': exact_matches,
                'total_comparisons': total_comparisons,
                'overlap_percentage': round(overlap_percentage, 2),
                'rows_compared': min_rows
            })
    
    return results

@app.route('/save_annotation', methods=['POST'])
@login_required
def save_annotation():
    """Save updated annotation rows for an assignment"""
    try:
        data = request.get_json()
        assignment_id = data.get('assignment_id')
        rows = data.get('rows')
        if not assignment_id or not isinstance(rows, list):
            return jsonify({'error': 'Missing assignment_id or rows'}), 400

        assignment = AnnotationAssignment.query.get(assignment_id)
        if not assignment or assignment.user_id != current_user.id:
            return jsonify({'error': 'Access denied'}), 403
        if assignment.status == 'completed':
            return jsonify({'error': 'Annotation already completed'}), 400

        # Save each row
        for row in rows:
            row_index = row.get('row_index')
            row_data = row.get('data')
            if row_index is None or row_data is None:
                continue  # skip invalid rows
            # Serialize row_data to JSON string
            row_json = json.dumps(row_data, ensure_ascii=False)
            # Check if row already exists
            annotation_row = AnnotationRow.query.filter_by(assignment_id=assignment_id, row_index=row_index).first()
            if annotation_row:
                annotation_row.data = row_json
                annotation_row.updated_at = datetime.utcnow()
            else:
                annotation_row = AnnotationRow(
                    assignment_id=assignment_id,
                    row_index=row_index,
                    data=row_json,
                    updated_at=datetime.utcnow()
                )
                db.session.add(annotation_row)
        db.session.commit()
        return jsonify({'success': True, 'message': 'Annotation saved successfully'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@app.route('/admin/download_file/<int:file_id>')
@login_required
def download_file(file_id):
    """Download the original CSV file"""
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    annotation_file = AnnotationFile.query.get_or_404(file_id)
    
    # Check if user can access this file
    if not can_user_access_file(current_user.id, file_id):
        flash('Access denied. You can only download files you own.', 'error')
        return redirect(url_for('dashboard'))
    
    try:
        # Check if file exists
        if not os.path.exists(annotation_file.file_path):
            flash('File not found.', 'error')
            return redirect(url_for('dashboard'))
        
        return send_file(annotation_file.file_path, 
                       as_attachment=True, 
                       download_name=annotation_file.original_filename)
    except Exception as e:
        flash(f'Error downloading file: {str(e)}', 'error')
        return redirect(url_for('dashboard'))

@app.route('/admin/download/<int:assignment_id>')
@login_required
def download_annotation(assignment_id):
    if not (current_user.is_admin or current_user.is_manager):
        flash('Access denied. Admin or Manager privileges required.', 'error')
        return redirect(url_for('dashboard'))
    assignment = AnnotationAssignment.query.get_or_404(assignment_id)
    if not can_user_access_assignment(current_user.id, assignment_id):
        flash('Access denied. You can only download assignments you own.', 'error')
        return redirect(url_for('dashboard'))
    if assignment.status != 'completed':
        flash('Annotation not completed yet.', 'error')
        return redirect(url_for('dashboard'))
    try:
        # Read the original CSV file for all rows and columns
        df = pd.read_csv(assignment.annotation_file.file_path, dtype=str, keep_default_na=False)
        all_columns = df.columns.tolist()
        # Get all annotation rows from DB for this assignment
        db_rows = {row.row_index: json.loads(row.data) for row in AnnotationRow.query.filter_by(assignment_id=assignment_id).all()}
        # Prepare CSV in memory
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=all_columns)
        writer.writeheader()
        for idx, csv_row in enumerate(df.to_dict('records')):
            # Merge DB annotation if exists, else use original CSV data
            row_data = csv_row.copy()
            if idx in db_rows:
                row_data.update(db_rows[idx])
            filtered_row = {col: row_data.get(col, '') for col in all_columns}
            writer.writerow(filtered_row)
        output.seek(0)
        # Send as file
        filename = assignment.annotation_file.original_filename.replace('.csv', '') + '_' + assignment.user.username + '.csv'
        return Response(output.getvalue(), mimetype='text/csv', headers={
            'Content-Disposition': f'attachment; filename={filename}'
        })
    except Exception as e:
        flash('Error exporting annotation data', 'error')
        return redirect(url_for('dashboard'))

@app.route('/admin/delete_file/<int:file_id>')
@login_required
def delete_annotation_file(file_id):
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    annotation_file = AnnotationFile.query.get_or_404(file_id)
    try:
        # Delete the original file
        if os.path.exists(annotation_file.file_path):
            os.remove(annotation_file.file_path)
        # Delete all user copies
        assignments = AnnotationAssignment.query.filter_by(file_id=file_id).all()
        for assignment in assignments:
            if assignment.user_file_path:
                user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], assignment.user_file_path)
                if os.path.exists(user_file_path):
                    os.remove(user_file_path)
            # Delete all AnnotationRow records for this assignment
            AnnotationRow.query.filter_by(assignment_id=assignment.id).delete()
        # Delete all assignments
        AnnotationAssignment.query.filter_by(file_id=file_id).delete()
        # Delete the annotation file record
        db.session.delete(annotation_file)
        db.session.commit()
        flash(f'File "{annotation_file.original_filename}" and all related data have been deleted.', 'success')
    except Exception as e:
        db.session.rollback()
        flash(f'Error deleting file: {str(e)}', 'error')
    return redirect(url_for('dashboard'))


@app.route('/admin/users')
@login_required
def manage_users():
    """Admin interface to manage users"""
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    users = User.query.all()
    return render_template('manage_users.html', users=users)

@app.route('/admin/users/delete/<int:user_id>', methods=['POST'])
@login_required
def delete_user(user_id):
    """Delete a user (admin only)"""
    if not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Access denied'}), 403
    
    if user_id == current_user.id:
        return jsonify({'success': False, 'error': 'Cannot delete your own account'}), 400
    
    user = User.query.get_or_404(user_id)
    
    try:
        # Delete user's assignments and files
        assignments = AnnotationAssignment.query.filter_by(user_id=user_id).all()
        for assignment in assignments:
            # Delete user's CSV file if it exists
            if assignment.user_file_path:
                user_file_path = os.path.join(app.config['UPLOAD_FOLDER'], assignment.user_file_path)
                if os.path.exists(user_file_path):
                    os.remove(user_file_path)
            # Delete related annotation rows and notifications first to avoid FK constraint errors
            try:
                AnnotationRow.query.filter_by(assignment_id=assignment.id).delete()
            except Exception:
                pass
            try:
                Notification.query.filter_by(assignment_id=assignment.id).delete()
            except Exception:
                pass
            db.session.delete(assignment)
        
        # Delete notifications related to this user
        notifications = Notification.query.filter_by(admin_id=user_id).all()
        for notification in notifications:
            db.session.delete(notification)
        
        # Delete the user
        db.session.delete(user)
        db.session.commit()
        
        return jsonify({'success': True, 'message': f'User {user.username} deleted successfully'})
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/admin/users/reset_password/<int:user_id>', methods=['POST'])
@login_required
def reset_user_password(user_id):
    """Reset a user's password (admin only)"""
    if not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Access denied'}), 403
    
    user = User.query.get_or_404(user_id)
    new_password = request.json.get('new_password', 'password123')
    
    try:
        user.set_password(new_password)
        db.session.commit()
        
        return jsonify({'success': True, 'message': f'Password for {user.username} reset successfully'})
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('index'))

# Manager Management Routes
@app.route('/admin/managers')
@login_required
def manage_managers():
    """Admin interface to manage managers and assign users"""
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    
    managers = User.query.filter_by(is_manager=True).all()
    all_users = User.query.filter_by(is_admin=False, is_manager=False, is_approved=True).all()
    
    # Get manager-user assignments
    manager_assignments = {}
    for manager in managers:
        managed_users = get_manager_users(manager.id)
        manager_assignments[manager.id] = managed_users
    
    # Convert User objects to dictionaries for JSON serialization
    managers_data = []
    for manager in managers:
        managers_data.append({
            'id': manager.id,
            'username': manager.username,
            'first_name': manager.first_name,
            'last_name': manager.last_name,
            'email': manager.email,
            'organization': manager.organization,
            'created_at': manager.created_at.isoformat() if manager.created_at else None
        })
    
    all_users_data = []
    for user in all_users:
        all_users_data.append({
            'id': user.id,
            'username': user.username,
            'first_name': user.first_name,
            'last_name': user.last_name,
            'email': user.email,
            'organization': user.organization
        })
    
    # Convert managed users to dictionaries
    manager_assignments_data = {}
    for manager_id, managed_users in manager_assignments.items():
        manager_assignments_data[manager_id] = []
        for user in managed_users:
            manager_assignments_data[manager_id].append({
                'id': user.id,
                'username': user.username,
                'first_name': user.first_name,
                'last_name': user.last_name,
                'email': user.email,
                'organization': user.organization
            })
    
    return render_template('manage_managers.html', 
                         managers=managers, 
                         all_users=all_users, 
                         manager_assignments=manager_assignments,
                         managers_data=managers_data,
                         all_users_data=all_users_data,
                         manager_assignments_data=manager_assignments_data)

@app.route('/admin/managers/create_manager', methods=['POST'])
@login_required
def create_manager():
    """Create a new manager (admin only)"""
    if not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Access denied'}), 403
    
    data = request.get_json()
    username = data.get('username')
    password = data.get('password', 'manager123')
    
    if not username:
        return jsonify({'success': False, 'error': 'Username is required'}), 400
    
    # Check if user exists
    existing_user = User.query.filter_by(username=username).first()
    if existing_user:
        if existing_user.is_manager:
            return jsonify({'success': False, 'error': 'User is already a manager'}), 400
        else:
            # Promote existing user to manager
            existing_user.is_manager = True
            existing_user.is_approved = True
            if password != 'manager123':
                existing_user.set_password(password)
            db.session.commit()
            return jsonify({'success': True, 'message': f'User {username} promoted to manager'})
    else:
        # Create new manager user
        manager = User(
            username=username,
            email=data.get('email', f'{username}@manager.com'),
            first_name=data.get('first_name', 'Manager'),
            last_name=data.get('last_name', 'User'),
            organization=data.get('organization', 'Organization'),
            position=data.get('position', 'Manager'),
            phone=data.get('phone', 'N/A'),
            is_manager=True,
            is_approved=True
        )
        manager.set_password(password)
        db.session.add(manager)
        db.session.commit()
        return jsonify({'success': True, 'message': f'Manager {username} created successfully'})

@app.route('/admin/managers/assign_users/<int:manager_id>', methods=['POST'])
@login_required
def assign_users_to_manager(manager_id):
    """Assign users to a manager (admin only)"""
    if not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Access denied'}), 403
    
    manager = User.query.get_or_404(manager_id)
    if not manager.is_manager:
        return jsonify({'success': False, 'error': 'User is not a manager'}), 400
    
    data = request.get_json()
    user_ids = data.get('user_ids', [])
    
    try:
        # Remove existing assignments for this manager
        UserManager.query.filter_by(manager_id=manager_id).delete()
        
        # Add new assignments
        for user_id in user_ids:
            user = User.query.get(user_id)
            if user and not user.is_admin and not user.is_manager:
                user_manager = UserManager(manager_id=manager_id, user_id=user_id)
                db.session.add(user_manager)
        
        db.session.commit()
        return jsonify({'success': True, 'message': f'Users assigned to manager {manager.username}'})
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/admin/managers/remove_manager/<int:manager_id>', methods=['POST'])
@login_required
def remove_manager(manager_id):
    """Remove manager role from user (admin only)"""
    if not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Access denied'}), 403
    
    if manager_id == current_user.id:
        return jsonify({'success': False, 'error': 'Cannot remove your own manager role'}), 400
    
    manager = User.query.get_or_404(manager_id)
    if not manager.is_manager:
        return jsonify({'success': False, 'error': 'User is not a manager'}), 400
    
       
       
    try:
        # Remove user-manager relationships
        UserManager.query.filter_by(manager_id=manager_id).delete()
        
        # Transfer file ownership to admin or deactivate
        files = get_manager_files(manager_id)
        for file in files:
            file.is_active = False
        
        manager.is_manager = False
        
        db.session.commit()
        return jsonify({'success': True, 'message': f'Manager role removed from {manager.username}'})
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/admin/download_all_annotations')
@login_required
def download_all_annotations():
    """Admin: Download all annotation_row table content as a CSV with metadata and all editable columns."""
    if not current_user.is_admin:
        flash('Access denied. Admin privileges required.', 'error')
        return redirect(url_for('dashboard'))
    try:
        # Query all annotation rows with assignment, user, and file info
        rows = AnnotationRow.query.join(AnnotationAssignment).join(User, AnnotationAssignment.user_id == User.id).join(AnnotationFile, AnnotationAssignment.file_id == AnnotationFile.id).add_entity(AnnotationAssignment).add_entity(User).add_entity(AnnotationFile).order_by(AnnotationRow.assignment_id, AnnotationRow.row_index).all()
       
        if not rows:
            flash('No annotation data found in database.', 'error')
            return redirect(url_for('dashboard'))
        # Collect all editable columns across all files
        all_editable_columns = set()
        file_editable_columns = {}
        files = AnnotationFile.query.all()
        for f in files:
            try:
                cols = json.loads(f.editable_columns) if f.editable_columns else []
                file_editable_columns[f.id] = cols
                all_editable_columns.update(cols)
            except Exception:
                continue
        all_editable_columns = sorted(list(all_editable_columns))
        # CSV header: assignment_id, user, file, row_index, [all editable columns]
        fieldnames = [
            'assignment_id', 'user_id', 'username', 'file_id', 'file_name', 'row_index', 'updated_at'
        ] + all_editable_columns
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=fieldnames)
        writer.writeheader()
        for row, assignment, user, annotation_file in rows:
            row_data = json.loads(row.data)
            # Only include columns for this file, but fill all columns for CSV
            editable_cols = file_editable_columns.get(annotation_file.id, all_editable_columns)
            csv_row = {
                'assignment_id': assignment.id,
                'user_id': user.id,
                'username': user.username,
                'file_id': annotation_file.id,
                'file_name': annotation_file.original_filename,
                'row_index': row.row_index,
                'updated_at': row.updated_at.isoformat() if row.updated_at else ''
            }
            for col in all_editable_columns:
                csv_row[col] = row_data.get(col, '') if col in editable_cols else ''
            writer.writerow(csv_row)
        output.seek(0)
        filename = f'all_annotations_{datetime.utcnow().strftime("%Y%m%d_%H%M%S")}.csv'
        return Response(output.getvalue(), mimetype='text/csv', headers={
            'Content-Disposition': f'attachment; filename={filename}'
        })
    except Exception as e:
        flash(f'Error exporting all annotation data: {str(e)}', 'error')
        return redirect(url_for('dashboard'))

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
        create_admin_user()  # Create admin user on startup
    debug_mode = os.environ.get('FLASK_ENV', 'development') == 'development'
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', 5000))
    print(f"Launching Flask app on http://{host}:{port}")
    app.run(host=host, port=port, debug=debug_mode)

