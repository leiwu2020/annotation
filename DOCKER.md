# Docker Deployment Guide

This guide explains how to deploy the Annotation System using Docker.

## Prerequisites

- Docker installed on your system
- Docker Compose (optional, for easier deployment)

## Quick Start with Docker Compose

1. **Clone the repository:**
   ```bash
   git clone https://github.com/leiwu2020/annotation.git
   cd annotation
   ```

2. **Build and run with Docker Compose:**
   ```bash
   docker-compose up --build
   ```

3. **Access the application:**
   - Open your browser and go to `http://localhost:5000`
   - Default admin credentials:
     - Username: `admin`
     - Password: `admin123`

## Manual Docker Build

1. **Build the Docker image:**
   ```bash
   docker build -t annotation-system .
   ```

2. **Run the container:**
   ```bash
   docker run -d \
     --name annotation-app \
     -p 5000:5000 \
     -v annotation_data:/app/instance \
     -v annotation_uploads:/app/uploads \
     annotation-system
   ```

## Docker Commands

### Build the image
```bash
docker build -t annotation-system .
```

### Run the container
```bash
docker run -p 5000:5000 annotation-system
```

### Run with volumes (recommended)
```bash
docker run -d \
  --name annotation-app \
  -p 5000:5000 \
  -v annotation_data:/app/instance \
  -v annotation_uploads:/app/uploads \
  annotation-system
```

### Stop the container
```bash
docker stop annotation-app
```

### Remove the container
```bash
docker rm annotation-app
```

### View logs
```bash
docker logs annotation-app
```

### Access container shell
```bash
docker exec -it annotation-app /bin/bash
```

## Docker Compose Commands

### Start services
```bash
docker-compose up
```

### Start in background
```bash
docker-compose up -d
```

### Rebuild and start
```bash
docker-compose up --build
```

### Stop services
```bash
docker-compose down
```

### View logs
```bash
docker-compose logs -f
```

## Data Persistence

The Docker setup uses named volumes to persist data:

- `annotation_data`: Stores the SQLite database files
- `annotation_uploads`: Stores uploaded CSV files and user annotations

## Environment Variables

You can customize the application using environment variables:

- `FLASK_ENV`: Set to `production` for production deployment
- `HOST`: Host to bind to (default: `0.0.0.0` in Docker)
- `PORT`: Port to bind to (default: `5000`)

Example:
```bash
docker run -e FLASK_ENV=production -p 5000:5000 annotation-system
```

## Production Deployment

For production deployment, consider:

1. **Use a production WSGI server:**
   ```dockerfile
   # Add to Dockerfile
   RUN pip install gunicorn
   CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
   ```

2. **Use environment variables for secrets:**
   ```bash
   docker run -e SECRET_KEY=your-secret-key annotation-system
   ```

3. **Use external database:**
   - Configure PostgreSQL or MySQL
   - Update database connection in app.py

## Troubleshooting

### Container won't start
- Check logs: `docker logs annotation-app`
- Verify port 5000 is available
- Check if uploads directory is writable

### Database issues
- Ensure volumes are properly mounted
- Check database file permissions
- Verify SQLite installation

### File upload issues
- Check uploads directory permissions
- Verify disk space
- Check file size limits

## Security Notes

- Change default admin password after first login
- Use strong SECRET_KEY in production
- Consider using HTTPS in production
- Regularly update Docker images
- Use non-root user (already configured in Dockerfile)
