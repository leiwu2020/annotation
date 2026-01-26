#!/usr/bin/env python3
"""
Database migration script to add visible_columns field to AnnotationFile model.
Run this script once to update existing annotation files with default visible columns.
"""

import os
import sys
import json
from flask import Flask
from flask_sqlalchemy import SQLAlchemy

# Add the current directory to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app, db, AnnotationFile

def migrate_visible_columns():
    """Add visible_columns field to existing AnnotationFile records"""
    with app.app_context():
        try:
            # Get all annotation files that don't have visible_columns set
            files_to_update = AnnotationFile.query.filter(
                (AnnotationFile.visible_columns.is_(None)) | 
                (AnnotationFile.visible_columns == '')
            ).all()
            
            print(f"Found {len(files_to_update)} annotation files to update...")
            
            for file_record in files_to_update:
                try:
                    # Read the CSV file to get all columns
                    import pandas as pd
                    df = pd.read_csv(file_record.file_path)
                    all_columns = df.columns.tolist()
                    
                    # Set all columns as visible by default
                    file_record.visible_columns = json.dumps(all_columns)
                    
                    print(f"Updated file '{file_record.original_filename}' with {len(all_columns)} visible columns")
                    
                except Exception as e:
                    print(f"Error processing file '{file_record.original_filename}': {e}")
                    continue
            
            # Commit all changes
            db.session.commit()
            print(f"Successfully updated {len(files_to_update)} annotation files!")
            
        except Exception as e:
            print(f"Migration failed: {e}")
            db.session.rollback()
            return False
    
    return True

if __name__ == "__main__":
    print("Starting visible_columns migration...")
    success = migrate_visible_columns()
    
    if success:
        print("Migration completed successfully!")
    else:
        print("Migration failed!")
        sys.exit(1)









