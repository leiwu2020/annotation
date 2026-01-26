#!/usr/bin/env python3
"""
Script to convert relative image paths to S3 paths in the CSV file
"""
import pandas as pd

# Configuration
INPUT_FILE = '1669-v2_matched.csv'
OUTPUT_FILE = '1669-v2_matched_s3.csv'
S3_BASE_PATH = 's3://eval-hop/a6664151-19b7-4fc8-bb0a-4d733f1a673c/'
OLD_PREFIX = 'evaluation_data/a6664151-19b7-4fc8-bb0a-4d733f1a673c/'

def convert_to_s3_path(image_path):
    """Convert relative path to S3 path"""
    if pd.isna(image_path) or image_path == '':
        return ''
    
    # Remove the old prefix if present
    if image_path.startswith(OLD_PREFIX):
        relative_path = image_path[len(OLD_PREFIX):]
        return S3_BASE_PATH + relative_path
    else:
        # If the path doesn't start with the expected prefix, just append to S3 base
        return S3_BASE_PATH + image_path

def main():
    print(f"Reading {INPUT_FILE}...")
    df = pd.read_csv(INPUT_FILE)
    
    print(f"Total rows: {len(df)}")
    print(f"\nColumns: {df.columns.tolist()}")
    
    # Show sample of original paths
    print("\n=== Sample Original Paths ===")
    print(df['Image_Path'].head(3).tolist())
    
    # Convert Image_Path to S3 paths
    print("\nConverting paths to S3 format...")
    df['Image_Path'] = df['Image_Path'].apply(convert_to_s3_path)
    
    # Show sample of converted paths
    print("\n=== Sample Converted S3 Paths ===")
    print(df['Image_Path'].head(3).tolist())
    
    # Save to new file
    print(f"\nSaving to {OUTPUT_FILE}...")
    df.to_csv(OUTPUT_FILE, index=False)
    
    print(f"\n✓ Success! File saved to {OUTPUT_FILE}")
    print(f"  - Total rows: {len(df)}")
    print(f"  - Columns: {', '.join(df.columns.tolist())}")
    print(f"\nYou can now use this file in your annotation system!")
    print(f"Set 'Image_Path' as the image path column in the admin configuration.")

if __name__ == '__main__':
    main()

