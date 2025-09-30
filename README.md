# Annotation Website

A Flask web application that allows users to register and login, with admin approval system for user management.

## Features

- User registration with comprehensive information collection
- User login/logout functionality
- Admin dashboard for approving/rejecting user registrations
- Modern, responsive web interface
- SQLite database for user management
- Secure password hashing
- Admin account with special privileges

## Setup

1. **Activate the conda environment:**
   ```bash
   conda activate annotation
   ```

2. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Run the application:**
   ```bash
   python app.py
   ```

4. **Access the website:**
   Open your browser and go to `http://localhost:5000`

## Admin Account

The system automatically creates an admin account:
- **Username:** `admin`
- **Password:** `admin0516`

The admin account has special privileges to approve or reject user registrations.

## Database

The application uses SQLite database (`users.db`) which will be created automatically when you first run the app.

## User Registration Process

1. User fills out registration form with:
   - Username
   - Email
   - Password
   - First and Last name
   - Organization
   - Position
   - Phone number

2. Registration information appears in the admin dashboard for approval

3. Admin can approve or reject the registration from the admin dashboard

4. User account remains inactive until approved by administrator

5. Once approved, user can login and access the dashboard

## File Structure

```
annotation/
├── app.py                 # Main Flask application
├── requirements.txt       # Python dependencies
├── README.md             # This file
├── templates/            # HTML templates
│   ├── layout.html       # Base template
│   ├── index.html        # Home page
│   ├── register.html     # Registration form
│   ├── login.html        # Login form
│   └── dashboard.html    # User dashboard
└── static/
    └── css/
        └── style.css     # Stylesheet
```

## Security Notes

- Change the `SECRET_KEY` in production
- Use environment variables for sensitive configuration
- Consider using a more robust database in production
- Implement proper email validation and rate limiting
