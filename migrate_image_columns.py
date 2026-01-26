#!/usr/bin/env python
"""
Migration script to add image_path_column and image_visible columns to annotation_file table
"""
import sqlite3
import os
import sys

def migrate_database():
    # Check for both possible database locations
    db_paths = [
        'instance/annotation.db',
        'users.db',
        'instance/users.db'
    ]
    
    db_path = None
    for path in db_paths:
        if os.path.exists(path):
            db_path = path
            break
    
    if not db_path:
        print("No database file found. The database will be created automatically on first run.")
        return
    
    print(f"Found database at: {db_path}")
    
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()
        
        # Check if columns already exist
        cursor.execute("PRAGMA table_info(annotation_file)")
        columns = [row[1] for row in cursor.fetchall()]
        
        print(f"Existing columns: {columns}")
        
        # Add image_path_column if it doesn't exist
        if 'image_path_column' not in columns:
            print("Adding image_path_column column...")
            cursor.execute("""
                ALTER TABLE annotation_file 
                ADD COLUMN image_path_column VARCHAR(255)
            """)
            print("✓ Added image_path_column")
        else:
            print("✓ image_path_column already exists")
        
        # Add image_visible if it doesn't exist
        if 'image_visible' not in columns:
            print("Adding image_visible column...")
            cursor.execute("""
                ALTER TABLE annotation_file 
                ADD COLUMN image_visible BOOLEAN DEFAULT 0
            """)
            print("✓ Added image_visible")
        else:
            print("✓ image_visible already exists")
        
        conn.commit()
        conn.close()
        
        print("\n✓ Migration completed successfully!")
        
    except sqlite3.Error as e:
        print(f"Error during migration: {e}")
        sys.exit(1)

if __name__ == '__main__':
    migrate_database()
