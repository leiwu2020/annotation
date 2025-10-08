#!/bin/bash

# Deploy Annotation App to EC2 Server
# This script deploys the Docker image from ECR to an EC2 instance

set -e  # Exit on any error

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
IMAGE_TAG="${1:-latest}"  # Use first argument as tag, default to 'latest'
CONTAINER_NAME="annotation-app"
APP_PORT="${2:-5000}"     # Use second argument as port, default to 5000
HOST_PORT="${3:-5000}"    # Use third argument as host port, default to 5000

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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
        warning "Running as root. Consider using a non-root user with sudo privileges."
        DOCKER_CMD="docker"
        MKDIR_CMD="mkdir"
        CHOWN_CMD="chown"
        CP_CMD="cp"
        MV_CMD="mv"
        UFW_CMD="ufw"
        FIREWALL_CMD="firewall-cmd"
    elif sudo -n true 2>/dev/null; then
        success "Passwordless sudo detected. Proceeding with sudo commands."
        DOCKER_CMD="sudo docker"
        MKDIR_CMD="sudo mkdir"
        CHOWN_CMD="sudo chown"
        CP_CMD="sudo cp"
        MV_CMD="sudo mv"
        UFW_CMD="sudo ufw"
        FIREWALL_CMD="sudo firewall-cmd"
    else
        error "This script requires sudo privileges. Please run with sudo or configure passwordless sudo."
        echo ""
        echo "To configure passwordless sudo for your user:"
        echo "1. Edit sudoers file: sudo visudo"
        echo "2. Add this line (replace 'ubuntu' with your username):"
        echo "   ubuntu ALL=(ALL) NOPASSWD: ALL"
        echo ""
        echo "Or run the script with sudo:"
        echo "   sudo ./deploy-to-ec2.sh"
        echo ""
        exit 1
    fi
}

# Check if Docker is installed
check_docker() {
    log "Checking Docker installation..."
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install Docker first."
        echo "Installation commands:"
        echo "  curl -fsSL https://get.docker.com -o get-docker.sh"
        echo "  sudo sh get-docker.sh"
        echo "  sudo usermod -aG docker \$USER"
        echo "  # Log out and back in, then run: sudo systemctl enable docker"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log "Docker daemon is not running. Attempting to start..."
        
        # Try different init systems
        if command -v systemctl &> /dev/null; then
            log "Using systemctl to start Docker..."
            $SYSTEMCTL_CMD start docker
            $SYSTEMCTL_CMD enable docker
        elif command -v service &> /dev/null; then
            log "Using service command to start Docker..."
            $DOCKER_CMD service docker start
        elif command -v rc-service &> /dev/null; then
            log "Using rc-service to start Docker..."
            sudo rc-service docker start
        else
            warning "Could not determine init system. Please start Docker manually:"
            echo "  sudo dockerd &"
            echo "  # Or install Docker service properly"
        fi
        
        # Wait a moment for Docker to start
        sleep 3
        
        # Check again
        if ! docker info &> /dev/null; then
            error "Docker daemon failed to start. Please start Docker manually."
            exit 1
        fi
    fi
    
    success "Docker is installed and running"
}

# Install AWS CLI if not present
install_aws_cli() {
    log "Checking AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        warning "AWS CLI not found. Installing..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
        success "AWS CLI installed"
    else
        success "AWS CLI is already installed"
    fi
}

# Authenticate with ECR
authenticate_ecr() {
    log "Authenticating with ECR..."
    if aws ecr get-login-password --region us-east-1 | $DOCKER_CMD login --username AWS --password-stdin $ECR_REGISTRY; then
        success "Successfully authenticated with ECR"
    else
        error "Failed to authenticate with ECR. Please check your AWS credentials."
        exit 1
    fi
}

# Create necessary directories
create_directories() {
    log "Creating application directories..."
    $MKDIR_CMD -p /opt/annotation-app/{uploads,instance,logs}
    $CHOWN_CMD -R 1000:1000 /opt/annotation-app
    success "Directories created at /opt/annotation-app"
}

# Pull the Docker image
pull_image() {
    log "Pulling Docker image: $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
    if $DOCKER_CMD pull $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG; then
        success "Successfully pulled image"
    else
        error "Failed to pull image from ECR"
        exit 1
    fi
}

# Stop and remove existing container if it exists
cleanup_existing_container() {
    log "Checking for existing container..."
    if $DOCKER_CMD ps -a --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        warning "Existing container found. Stopping and removing..."
        $DOCKER_CMD stop $CONTAINER_NAME || true
        $DOCKER_CMD rm $CONTAINER_NAME || true
        success "Existing container cleaned up"
    fi
}

# Deploy the container
deploy_container() {
    log "Deploying container..."
    
    # Create a docker-compose.yml file for easier management
    cat > /tmp/docker-compose.yml << EOF
version: '3.8'
services:
  annotation-app:
    image: $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - "$HOST_PORT:$APP_PORT"
    volumes:
      - /opt/annotation-app/uploads:/app/uploads
      - /opt/annotation-app/instance:/app/instance
      - /opt/annotation-app/logs:/app/logs
    environment:
      - FLASK_ENV=production
      - PYTHONUNBUFFERED=1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:$APP_PORT/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    # Deploy using docker-compose
    if $DOCKER_CMD-compose -f /tmp/docker-compose.yml up -d; then
        success "Container deployed successfully"
    else
        error "Failed to deploy container"
        exit 1
    fi
}

# Wait for container to be healthy
wait_for_health() {
    log "Waiting for container to be healthy..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if $DOCKER_CMD ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$CONTAINER_NAME.*Up.*healthy"; then
            success "Container is healthy and running"
            return 0
        elif $DOCKER_CMD ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$CONTAINER_NAME.*Up"; then
            log "Container is running but health check pending... (attempt $attempt/$max_attempts)"
        else
            error "Container failed to start properly"
            $DOCKER_CMD logs $CONTAINER_NAME --tail 20
            exit 1
        fi
        
        sleep 2
        ((attempt++))
    done
    
    warning "Container is running but health check didn't complete in time"
    $DOCKER_CMD logs $CONTAINER_NAME --tail 10
}

# Show deployment information
show_deployment_info() {
    echo ""
    echo "=========================================="
    success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    echo "=========================================="
    echo ""
    echo "Container Information:"
    echo "  Name: $CONTAINER_NAME"
    echo "  Image: $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
    echo "  Status: $($DOCKER_CMD ps --format '{{.Status}}' --filter name=$CONTAINER_NAME)"
    echo ""
    echo "Access Information:"
    echo "  Local: http://localhost:$HOST_PORT"
    echo "  External: http://$(curl -s http://checkip.amazonaws.com/):$HOST_PORT"
    echo ""
    echo "Directories:"
    echo "  Uploads: /opt/annotation-app/uploads"
    echo "  Database: /opt/annotation-app/instance"
    echo "  Logs: /opt/annotation-app/logs"
    echo ""
    echo "Management Commands:"
    echo "  View logs: $DOCKER_CMD logs $CONTAINER_NAME"
    echo "  Stop: $DOCKER_CMD stop $CONTAINER_NAME"
    echo "  Start: $DOCKER_CMD start $CONTAINER_NAME"
    echo "  Restart: $DOCKER_CMD restart $CONTAINER_NAME"
    echo "  Shell access: $DOCKER_CMD exec -it $CONTAINER_NAME /bin/bash"
    echo ""
    echo "Docker Compose:"
    echo "  Stop: $DOCKER_CMD-compose -f /opt/annotation-app/docker-compose.yml down"
    echo "  Start: $DOCKER_CMD-compose -f /opt/annotation-app/docker-compose.yml up -d"
    echo ""
}

# Create auto-start service
create_autostart_service() {
    log "Creating auto-start service..."
    
    # Move docker-compose.yml to permanent location
    $MV_CMD /tmp/docker-compose.yml /opt/annotation-app/
    
    # Try different init systems
    if command -v systemctl &> /dev/null; then
        log "Creating systemd service for auto-start..."
        
        cat > /tmp/annotation-app.service << EOF
[Unit]
Description=Annotation App Docker Container
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/annotation-app
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

        $CP_CMD /tmp/annotation-app.service /etc/systemd/system/
        $SYSTEMCTL_CMD daemon-reload
        $SYSTEMCTL_CMD enable annotation-app.service
        success "Systemd service created and enabled"
        
    elif command -v update-rc.d &> /dev/null; then
        log "Creating init.d script for auto-start..."
        
        cat > /tmp/annotation-app << EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          annotation-app
# Required-Start:    docker
# Required-Stop:     docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       Annotation App Docker Container
### END INIT INFO

cd /opt/annotation-app
case "\$1" in
    start)
        docker-compose up -d
        ;;
    stop)
        docker-compose down
        ;;
    restart)
        docker-compose down
        docker-compose up -d
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF

        $CP_CMD /tmp/annotation-app /etc/init.d/
        chmod +x /etc/init.d/annotation-app
        update-rc.d annotation-app defaults
        success "Init.d script created and enabled"
        
    elif command -v rc-update &> /dev/null; then
        log "Creating OpenRC service for auto-start..."
        
        cat > /tmp/annotation-app << EOF
#!/sbin/openrc-run
command="/usr/bin/docker-compose"
command_args="up -d"
command_user="root"
command_background="yes"
pidfile="/var/run/annotation-app.pid"
start_stop_daemon_args="--chdir /opt/annotation-app"
depend() {
    need docker
}
EOF

        $CP_CMD /tmp/annotation-app /etc/init.d/
        chmod +x /etc/init.d/annotation-app
        rc-update add annotation-app default
        success "OpenRC service created and enabled"
        
    else
        warning "Could not determine init system. Auto-start not configured."
        echo "To start the application manually:"
        echo "  cd /opt/annotation-app"
        echo "  docker-compose up -d"
    fi
}

# Setup firewall rules
setup_firewall() {
    log "Setting up firewall rules..."
    
    if command -v ufw &> /dev/null; then
        $UFW_CMD allow $HOST_PORT/tcp comment "Annotation App"
        success "UFW firewall rule added for port $HOST_PORT"
    elif command -v firewall-cmd &> /dev/null; then
        $FIREWALL_CMD --permanent --add-port=$HOST_PORT/tcp
        $FIREWALL_CMD --reload
        success "Firewalld rule added for port $HOST_PORT"
    else
        warning "No firewall detected. Please manually open port $HOST_PORT if needed."
    fi
}

# Main deployment function
main() {
    echo "=========================================="
    echo "  Annotation App EC2 Deployment Script"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  ECR Registry: $ECR_REGISTRY"
    echo "  Repository: $ECR_REPOSITORY"
    echo "  Image Tag: $IMAGE_TAG"
    echo "  Container Port: $APP_PORT"
    echo "  Host Port: $HOST_PORT"
    echo ""
    
    # Run deployment steps
    check_privileges
    check_docker
    install_aws_cli
    authenticate_ecr
    create_directories
    pull_image
    cleanup_existing_container
    deploy_container
    wait_for_health
    create_autostart_service
    setup_firewall
    show_deployment_info
    
    echo ""
    success "Deployment script completed successfully!"
    echo "Your annotation application is now running on port $HOST_PORT"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [IMAGE_TAG] [APP_PORT] [HOST_PORT]"
        echo ""
        echo "Arguments:"
        echo "  IMAGE_TAG    Docker image tag to deploy (default: latest)"
        echo "  APP_PORT     Container port (default: 5000)"
        echo "  HOST_PORT    Host port to bind (default: 5000)"
        echo ""
        echo "Examples:"
        echo "  $0                    # Deploy latest image on port 5000"
        echo "  $0 v1.0.0            # Deploy v1.0.0 image on port 5000"
        echo "  $0 latest 5000 8080  # Deploy latest on container port 5000, host port 8080"
        exit 0
        ;;
    *)
        main
        ;;
esac
