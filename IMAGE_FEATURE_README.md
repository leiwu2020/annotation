# Image Viewer Feature

This feature allows admins and managers to configure image viewing from S3 paths in the annotation interface.

## Features

- **Admin/Manager Configuration**: Enable image viewer and specify which column contains image paths
- **S3 Integration**: Fetch and display images directly from S3 buckets
- **Multi-format Support**: 
  - DICOM files (.dcm)
  - PNG images (.png)
  - JPEG images (.jpg, .jpeg)
- **Modal Viewer**: Click image icon to view full-size image in a modal popup
- **Responsive Design**: Works on desktop, tablet, and mobile devices

## Setup Instructions

### 1. Install Dependencies

```bash
pip install -r requirements.txt
```

New dependencies added:
- `boto3==1.34.84` - AWS SDK for S3 access
- `pydicom==2.4.4` - DICOM file handling
- `Pillow==10.3.0` - Image processing

### 2. Configure AWS Credentials

The application needs AWS credentials to access S3. Configure them in one of these ways:

**Option 1: Environment Variables**
```bash
export AWS_ACCESS_KEY_ID="your_access_key"
export AWS_SECRET_ACCESS_KEY="your_secret_key"
export AWS_DEFAULT_REGION="us-east-1"
```

**Option 2: AWS Credentials File**
```bash
aws configure
```

**Option 3: IAM Role** (for EC2 instances)
Attach an IAM role with S3 read permissions to your EC2 instance.

### 3. Migrate Database

Run the migration script to add new columns to your database:

```bash
python migrate_image_columns.py
```

Or simply restart your Flask application - it will automatically create the new columns.

## Usage Guide

### For Admins/Managers

1. **Upload CSV File**: Upload your CSV file with annotation data
2. **Configure File**:
   - Go to "Configure" for the file
   - Enable "Enable Image Viewer" checkbox
   - Select the column containing S3 image paths
   - The column should contain paths in format: `s3://bucket-name/path/to/image.dcm`
3. **Assign to Users**: Assign the configured file to users

### For Users (Annotators)

1. **Open Annotation Task**: Click on your assigned file
2. **View Images**: 
   - An "Image" column appears with an image icon 📷 for each row
   - Click the icon to view the full-size image in a popup
   - Click the X or outside the image to close
3. **Annotate**: Continue with your annotation tasks as normal

## S3 Path Format

Image paths in your CSV should follow this format:

```
s3://bucket-name/folder/subfolder/image.dcm
s3://my-images/scans/patient123/scan001.dcm
s3://medical-data/xrays/2024/01/image.png
```

## Supported Image Formats

| Format | Extension | Notes |
|--------|-----------|-------|
| DICOM  | .dcm      | Medical imaging format, automatically converted to PNG for display |
| PNG    | .png      | Standard web image format |
| JPEG   | .jpg, .jpeg | Standard web image format |

## IAM Permissions Required

Your AWS credentials need the following S3 permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-bucket-name/*",
        "arn:aws:s3:::your-bucket-name"
      ]
    }
  ]
}
```

## Troubleshooting

### Image Not Loading

**Error**: "Image not found in S3"
- Check that the S3 path is correct
- Verify the file exists in S3
- Ensure AWS credentials have read access to the bucket

**Error**: "S3 bucket not found"
- Verify the bucket name is correct
- Check that the bucket exists in your AWS account
- Ensure credentials have ListBucket permission

**Error**: "Access Denied"
- Check IAM permissions for your AWS credentials
- Verify bucket policies allow access
- Ensure the object is not encrypted (or credentials have decrypt permissions)

### DICOM Files Not Displaying

- Ensure `pydicom` is installed: `pip install pydicom`
- Verify the DICOM file has pixel data
- Check the DICOM file is not corrupted

### AWS Credentials Not Working

1. Test credentials with AWS CLI:
   ```bash
   aws s3 ls s3://your-bucket-name/
   ```

2. Check credentials are loaded:
   ```python
   import boto3
   s3 = boto3.client('s3')
   print(s3.list_buckets())
   ```

## Security Considerations

1. **Least Privilege**: Grant only necessary S3 permissions
2. **Bucket Policies**: Use bucket policies to restrict access
3. **Encryption**: Consider using S3 server-side encryption
4. **Private Buckets**: Keep image buckets private, access through IAM only
5. **Audit Logging**: Enable CloudTrail for S3 access auditing

## Performance Tips

1. **Image Size**: Optimize image file sizes before uploading to S3
2. **Caching**: Browser automatically caches displayed images
3. **Lazy Loading**: Images are only loaded when clicked
4. **Memory Management**: Modal clears image data when closed

## API Endpoint

### POST /get_image

Fetches an image from S3 and returns it as base64-encoded data.

**Request**:
```json
{
  "image_path": "s3://bucket/path/image.dcm"
}
```

**Response**:
```json
{
  "success": true,
  "image": "data:image/png;base64,iVBORw0KGgoAAAANS...",
  "format": "dcm"
}
```

**Error Response**:
```json
{
  "error": "Image not found in S3"
}
```

## Database Schema

New columns added to `annotation_file` table:

```sql
image_path_column VARCHAR(255)  -- Column name containing image paths
image_visible BOOLEAN DEFAULT 0  -- Whether to show image icon
```

## Future Enhancements

Potential improvements for future versions:

- [ ] Support for more image formats (TIFF, BMP, etc.)
- [ ] Image zoom and pan controls
- [ ] Image annotations (drawings, markers)
- [ ] Batch image loading
- [ ] S3 presigned URL caching
- [ ] Support for other cloud storage (Azure Blob, Google Cloud Storage)
- [ ] Image metadata display (dimensions, format, etc.)
- [ ] Thumbnail generation for faster previews

## License

This feature is part of the Annotation Application project.








