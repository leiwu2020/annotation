# ECR Deployment Guide

## Docker Image in ECR

Your annotation application has been successfully pushed to Amazon ECR:

**Repository URI:** `517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app`

**Available Tags:**
- `latest` - Latest version
- `v1.0.0` - Versioned release

## Features Included

✅ **Multi-choice column improvements** - Better layout and fitting within page visualization  
✅ **Dropdown sizing fixes** - Dropdowns now fit properly within text areas  
✅ **Column visibility control** - Admins/managers can configure which columns to show  
✅ **Manager dashboard fixes** - Fixed download functionality for completed annotations  
✅ **Database schema** - Includes `visible_columns` field for column configuration  

## How to Deploy

### 1. Pull and Run from ECR

```bash
# Authenticate with ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com

# Pull the image
docker pull 517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest

# Run the container
docker run -d \
  --name annotation-app \
  -p 5000:5000 \
  -v $(pwd)/uploads:/app/uploads \
  -v $(pwd)/instance:/app/instance \
  517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest
```

### 2. Using Docker Compose

Create a `docker-compose.yml` file:

```yaml
version: '3.8'
services:
  annotation-app:
    image: 517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest
    ports:
      - "5000:5000"
    volumes:
      - ./uploads:/app/uploads
      - ./instance:/app/instance
    environment:
      - FLASK_ENV=production
```

Then run:
```bash
docker-compose up -d
```

### 3. AWS ECS/Fargate Deployment

Use the ECR image URI in your ECS task definition:

```json
{
  "family": "annotation-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::517569678285:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "annotation-app",
      "image": "517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest",
      "portMappings": [
        {
          "containerPort": 5000,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/annotation-app",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

## Image Details

- **Size:** ~832MB
- **Base Image:** Python 3.11-slim
- **Port:** 5000
- **Health Check:** Built-in Flask health monitoring
- **Volumes:** `/app/uploads` and `/app/instance` for persistent data

## Testing the Deployment

Once deployed, access the application at:
- **Local:** http://localhost:5000
- **Remote:** http://your-server-ip:5000

Test the key features:
1. User registration and login
2. File upload and configuration
3. Column visibility settings
4. Annotation with improved multi-choice layout
5. Manager dashboard with download functionality

## Security Notes

- Image scanning is enabled on push
- Uses AES256 encryption
- Repository is private to your AWS account
- Consider using IAM roles for ECS deployments









