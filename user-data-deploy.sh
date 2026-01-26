#!/bin/bash

# Comprehensive user data script for automatic deployment
# This script runs during EC2 instance initialization

set -e

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
REGION="us-east-1"

# Log function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/annotation-deploy.log
}

# Error function
error() {
    echo "[ERROR] $1" | tee -a /var/log/annotation-deploy.log
}

# Success function
success() {
    echo "[SUCCESS] $1" | tee -a /var/log/annotation-deploy.log
}

# Start logging
log "Starting annotation app deployment..."

# Update system
log "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install required packages
log "Installing required packages..."
apt-get install -y docker.io awscli curl unzip python3-pip

# Start and enable Docker
log "Starting Docker service..."
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Install Docker Compose
log "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create application directory
log "Creating application directory..."
mkdir -p /opt/annotation-app/{uploads,instance,logs}
chown -R 1000:1000 /opt/annotation-app

# Wait for instance metadata to be available
log "Waiting for instance metadata..."
sleep 30

# Configure AWS CLI (use instance profile)
log "Configuring AWS CLI..."
aws configure set region $REGION

# Test AWS CLI
log "Testing AWS CLI..."
if aws sts get-caller-identity &>/dev/null; then
    success "AWS CLI configured successfully"
else
    error "AWS CLI configuration failed"
    exit 1
fi

# Login to ECR
log "Logging in to ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

# Pull Docker image
log "Pulling Docker image from ECR..."
docker pull $ECR_REGISTRY/$ECR_REPOSITORY:latest

# Create docker-compose file
log "Creating docker-compose configuration..."
cat > /opt/annotation-app/docker-compose.yml << EOF
version: '3.8'

services:
  annotation-app:
    image: $ECR_REGISTRY/$ECR_REPOSITORY:latest
    container_name: annotation-app
    ports:
      - "5000:5000"
    volumes:
      - ./uploads:/app/uploads
      - ./instance:/app/instance
      - ./logs:/app/logs
    environment:
      - FLASK_ENV=production
      - HOST=0.0.0.0
      - PORT=5000
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
EOF

# Start the application
log "Starting the application..."
cd /opt/annotation-app
docker-compose up -d

# Wait for application to be ready
log "Waiting for application to be ready..."
for i in {1..30}; do
    if curl -f http://localhost:5000/ &>/dev/null; then
        success "Application is ready!"
        
        # Get public IP and log final information
        PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
        
        log "=========================================="
        log "DEPLOYMENT COMPLETED SUCCESSFULLY!"
        log "=========================================="
        log "Application Information:"
        log "  Web Interface: http://$PUBLIC_IP:5000"
        log "  Local Interface: http://localhost:5000"
        log ""
        log "Management Commands:"
        log "  View logs: docker logs annotation-app"
        log "  Restart app: docker restart annotation-app"
        log "  Stop app: docker stop annotation-app"
        log "  View status: docker ps"
        log "=========================================="
        
        break
    fi
    log "Waiting... (attempt $i/30)"
    sleep 10
done

# Create a status file
echo "deployment_completed_$(date +%Y%m%d_%H%M%S)" > /opt/annotation-app/deployment-status.txt

log "Deployment script completed"








