# Image Feature Usage Guide

## Overview
The annotation app now supports displaying medical images (DCM, PNG, JPG) from S3 or HTTP/HTTPS URLs alongside annotation data. Images can be matched to data rows using BatchID and StudyUID fields.

## Setup Instructions

### 1. Admin Configuration

1. **Upload your annotation CSV file** through the admin dashboard
2. **Navigate to Configure File** for the uploaded file
3. **Enable Image Viewer**: Check the "Enable Image Viewer" checkbox
4. **Choose Image Source Type**:
   - **Use Mapping File (CSV)**: Select this option to use a separate CSV file for image mappings
   - Enter the filename (e.g., `1669-v2_matched.csv`)
   - The CSV file should have these columns: `BatchID`, `StudyUID`, `Image_Path`
   - Place the CSV file in the project root directory

### 2. Image Mapping CSV Format

Your image mapping CSV should look like this:

```csv
BatchID,StudyUID,Image_Path
76369e45-85fc-45d8-a7c7-ef94b6f32cad,1.2.346.113654.2.70.1.261459180117705895356741437340889170437,s3://eval-hop/path/to/image.dcm
1b8ac1be-bcc1-4d53-aede-f146f625e63b,1.2.346.113654.2.70.1.61134208306521070487172638049678374906,s3://eval-hop/path/to/another/image.dcm
```

**Requirements:**
- Must have columns: `BatchID`, `StudyUID`, `Image_Path`
- Image paths can be:
  - S3 paths: `s3://bucket-name/path/to/image.dcm`
  - HTTP/HTTPS URLs: `https://example.com/image.png`
- Supported formats: DCM (DICOM), PNG, JPG

### 3. Annotation Data Requirements

Your annotation CSV must have these columns for image matching:
- `BatchID`: Unique batch identifier
- `StudyUID`: Unique study identifier

The system will match images by creating a key: `{BatchID}_{StudyUID}` and looking it up in the mapping file.

### 4. User Experience

When users annotate files:
1. An **Image** column appears in the annotation table
2. Each row shows an image icon (📷) if a matching image is found
3. Clicking the icon opens a modal popup with the image
4. DCM files are automatically converted to viewable PNG format
5. Users can close the modal by clicking the X or clicking outside the image

## Technical Details

### Backend Changes
- `app.py`: Added image mapping loading in the `annotate_file()` function
- Mappings are loaded when `image_path_column` ends with `.csv`
- Creates dictionary mapping `{BatchID}_{StudyUID}` to `Image_Path`

### Frontend Changes
- `configure_file.html`: Added UI for selecting mapping source (column vs. CSV file)
- `annotate.html`: Updated to use image mappings and match by BatchID/StudyUID
- Modal popup already existed and supports DCM, PNG, JPG formats

### API Endpoints
- `/get_image`: Fetches images from S3 or HTTP/HTTPS URLs
  - Handles DICOM (.dcm) conversion to PNG
  - Returns base64-encoded image data
  - Requires AWS credentials configured for S3 access

## AWS Configuration

For S3 image access, ensure your environment has AWS credentials configured:

```bash
# Option 1: Environment variables
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_DEFAULT_REGION=us-east-1

# Option 2: AWS credentials file (~/.aws/credentials)
[default]
aws_access_key_id = your_access_key
aws_secret_access_key = your_secret_key
region = us-east-1
```

## Example Setup

1. Place `1669-v2_matched.csv` in the project root directory
2. Upload your annotation CSV (e.g., `annotations.csv`)
3. Configure the file:
   - Enable Image Viewer: ✓
   - Use Mapping File (CSV): ✓
   - Image Mapping CSV File Path: `1669-v2_matched.csv`
4. Select visible and editable columns as needed
5. Save configuration
6. Assign to users

Users will now see image icons for rows that have matching BatchID and StudyUID in the mapping file.

## Troubleshooting

### No images showing up
- Check that `BatchID` and `StudyUID` columns exist in your annotation data
- Verify the mapping CSV file is in the project root directory
- Check that values match exactly (case-sensitive)
- Look at console logs for "Loaded X image mappings" message

### Image fails to load
- Verify S3 bucket permissions and AWS credentials
- Check that image paths are correct
- Ensure image format is supported (DCM, PNG, JPG)
- Check network connectivity for HTTP/HTTPS URLs

### DCM files not displaying
- Ensure `pydicom` and `PIL` libraries are installed
- Check that DCM files are valid DICOM format
- Look for error messages in the browser console







