#!/bin/bash

# Simple deployment script for EC2 instance
# This script can be run directly on the EC2 instance

set -e

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
REGION="us-east-1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root or with sudo
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        DOCKER_CMD="docker"
        MKDIR_CMD="mkdir"
        CHOWN_CMD="chown"
        CP_CMD="cp"
        MV_CMD="mv"
    elif sudo -n true 2>/dev/null; then
        DOCKER_CMD="sudo docker"
        MKDIR_CMD="sudo mkdir"
        CHOWN_CMD="sudo chown"
        CP_CMD="sudo cp"
        MV_CMD="sudo mv"
    else
        error "This script requires root privileges or sudo access."
        exit 1
    fi
}

# Install AWS CLI if not present
install_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log "Installing AWS CLI..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        rm -rf awscliv2.zip aws/
        success "AWS CLI installed successfully"
    else
        success "AWS CLI already installed"
    fi
}

# Configure AWS CLI
configure_aws() {
    log "Configuring AWS CLI..."
    # Use instance profile if available, otherwise prompt for credentials
    if aws sts get-caller-identity &>/dev/null; then
        success "AWS CLI already configured"
    else
        warning "AWS CLI not configured. Please run 'aws configure' manually."
        exit 1
    fi
}

# Install Docker if not present
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "Installing Docker..."
        sudo apt-get update
        sudo apt-get install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker ubuntu
        success "Docker installed successfully"
    else
        success "Docker already installed"
    fi
}

# Install Docker Compose if not present
install_docker_compose() {
    if ! command -v docker-compose &> /dev/null; then
        log "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        success "Docker Compose installed successfully"
    else
        success "Docker Compose already installed"
    fi
}

# Create application directory
create_app_directory() {
    log "Creating application directory..."
    $MKDIR_CMD -p /opt/annotation-app/{uploads,instance,logs}
    $CHOWN_CMD -R 1000:1000 /opt/annotation-app
    success "Application directory created"
}

# Login to ECR
ecr_login() {
    log "Logging in to ECR..."
    aws ecr get-login-password --region $REGION | $DOCKER_CMD login --username AWS --password-stdin $ECR_REGISTRY
    success "ECR login successful"
}

# Pull Docker image
pull_image() {
    log "Pulling Docker image from ECR..."
    $DOCKER_CMD pull $ECR_REGISTRY/$ECR_REPOSITORY:latest
    success "Docker image pulled successfully"
}

# Create docker-compose file
create_docker_compose() {
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
    success "Docker Compose file created"
}

# Start the application
start_application() {
    log "Starting the application..."
    cd /opt/annotation-app
    $DOCKER_CMD-compose up -d
    success "Application started successfully"
}

# Wait for application to be ready
wait_for_app() {
    log "Waiting for application to be ready..."
    for i in {1..30}; do
        if curl -f http://localhost:5000/ &>/dev/null; then
            success "Application is ready!"
            return 0
        fi
        log "Waiting... (attempt $i/30)"
        sleep 10
    done
    error "Application failed to start within 5 minutes"
    return 1
}

# Show final information
show_final_info() {
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
    echo ""
    echo "=========================================="
    success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    echo "=========================================="
    echo ""
    echo "Application Information:"
    echo "  Web Interface: http://$PUBLIC_IP:5000"
    echo "  Local Interface: http://localhost:5000"
    echo ""
    echo "Management Commands:"
    echo "  View logs: $DOCKER_CMD logs annotation-app"
    echo "  Restart app: $DOCKER_CMD restart annotation-app"
    echo "  Stop app: $DOCKER_CMD stop annotation-app"
    echo "  View status: $DOCKER_CMD ps"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  Annotation App Deployment Script"
    echo "=========================================="
    echo ""
    
    check_privileges
    install_aws_cli
    configure_aws
    install_docker
    install_docker_compose
    create_app_directory
    ecr_login
    pull_image
    create_docker_compose
    start_application
    
    if wait_for_app; then
        show_final_info
    else
        error "Deployment failed - application not responding"
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo ""
        echo "This script will deploy the annotation application to the current EC2 instance."
        echo ""
        echo "Prerequisites:"
        echo "- EC2 instance with internet access"
        echo "- IAM role with ECR permissions (or AWS credentials configured)"
        echo "- Ubuntu/Debian-based system"
        echo ""
        exit 0
        ;;
    *)
        main
        ;;
esac








