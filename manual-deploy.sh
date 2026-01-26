#!/bin/bash
# Manual deployment script for image-annotation-app on EC2
# Run this script directly on your EC2 instance

set -e

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="image-annotation-app"
IMAGE_TAG="${1:-latest}"
CONTAINER_NAME="image-annotation-app"
APP_PORT="${2:-5000}"
HOST_PORT="${3:-5000}"
AWS_PROFILE="${AWS_PROFILE:-}"

echo "=========================================="
echo "  Manual Deployment: image-annotation-app"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "  Container: ${CONTAINER_NAME}"
echo "  Port: ${HOST_PORT}:${APP_PORT}"
echo "  AWS Profile: ${AWS_PROFILE:-default (IAM role)}"
echo ""

# Step 1: Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Step 1: Installing Docker..."
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS="unknown"
    fi
    
    case $OS in
        amzn|amazon)
            echo "Detected Amazon Linux. Installing Docker via yum..."
            sudo yum update -y
            sudo yum install -y docker
            sudo systemctl start docker
            sudo systemctl enable docker
            sudo usermod -aG docker $USER
            ;;
        ubuntu|debian)
            echo "Detected Ubuntu/Debian. Installing Docker..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker $USER
            rm get-docker.sh
            ;;
        *)
            echo "Unknown OS. Trying generic Docker installation..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh || {
                echo "ERROR: Docker installation failed"
                exit 1
            }
            sudo usermod -aG docker $USER
            rm get-docker.sh
            ;;
    esac
    
    echo "Docker installation completed"
    echo "Note: You may need to log out and log back in for Docker group changes to take effect"
    echo ""
else
    echo "Step 1: Docker is already installed"
    echo ""
fi

# Step 2: Start Docker service
echo "Step 2: Starting Docker service..."
sudo systemctl start docker || true
sudo systemctl enable docker || true
echo ""

# Step 3: Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    echo "Step 3: Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
    echo "AWS CLI installation completed"
    echo ""
else
    echo "Step 3: AWS CLI is already installed"
    echo ""
fi

# Step 4: Authenticate with ECR
echo "Step 4: Authenticating with ECR..."
ECR_LOGIN_SUCCESS=false

# Try with profile if set
if [ -n "${AWS_PROFILE}" ] && [ -f ~/.aws/config ]; then
    echo "Attempting to use AWS profile: ${AWS_PROFILE}"
    if aws ecr get-login-password --region us-east-1 --profile ${AWS_PROFILE} 2>/dev/null | sudo docker login --username AWS --password-stdin ${ECR_REGISTRY} 2>/dev/null; then
        echo "ECR authentication successful using profile ${AWS_PROFILE}"
        ECR_LOGIN_SUCCESS=true
    else
        echo "ECR authentication with profile failed, trying default credentials..."
    fi
fi

# Try with default credentials (IAM role) if profile didn't work
if [ "$ECR_LOGIN_SUCCESS" = false ]; then
    echo "Attempting to use default AWS credentials (IAM role)..."
    if aws ecr get-login-password --region us-east-1 2>/dev/null | sudo docker login --username AWS --password-stdin ${ECR_REGISTRY} 2>/dev/null; then
        echo "ECR authentication successful using default credentials"
        ECR_LOGIN_SUCCESS=true
    else
        echo "ERROR: ECR authentication failed"
        echo ""
        echo "Please ensure:"
        echo "  1. IAM role is attached to this EC2 instance with ECR permissions, OR"
        echo "  2. AWS credentials are configured (~/.aws/credentials or ~/.aws/config)"
        echo ""
        echo "Test credentials with: aws sts get-caller-identity"
        exit 1
    fi
fi
echo ""

# Step 5: Create directories
echo "Step 5: Creating required directories..."
sudo mkdir -p /opt/image-annotation-app/{uploads,instance,logs}
sudo chown -R 1000:1000 /opt/image-annotation-app
echo "Directories created: /opt/image-annotation-app/{uploads,instance,logs}"
echo ""

# Step 6: Stop and remove existing container
echo "Step 6: Stopping and removing existing container (if any)..."
sudo docker stop ${CONTAINER_NAME} 2>/dev/null || true
sudo docker rm ${CONTAINER_NAME} 2>/dev/null || true
echo ""

# Step 7: Pull Docker image
echo "Step 7: Pulling Docker image..."
sudo docker pull ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}
echo ""

# Step 8: Run container
echo "Step 8: Starting container..."

# Build docker run command
DOCKER_CMD="sudo docker run -d \
    --name ${CONTAINER_NAME} \
    --restart unless-stopped \
    -p ${HOST_PORT}:${APP_PORT} \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1"

# Add AWS profile if set and AWS config exists
if [ -n "${AWS_PROFILE}" ] && [ -d ~/.aws ]; then
    AWS_DIR=$(cd ~/.aws && pwd)
    DOCKER_CMD="${DOCKER_CMD} -v ${AWS_DIR}:/root/.aws:ro -e AWS_PROFILE=${AWS_PROFILE}"
    echo "Configuring container with AWS profile: ${AWS_PROFILE}"
fi

# Add image and execute
DOCKER_CMD="${DOCKER_CMD} ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

echo "Running: ${DOCKER_CMD}"
eval ${DOCKER_CMD}

echo ""
echo "=========================================="
echo "  Deployment Completed!"
echo "=========================================="
echo ""
echo "Container: ${CONTAINER_NAME}"
echo "Status: $(sudo docker ps --filter name=${CONTAINER_NAME} --format '{{.Status}}')"
echo ""
echo "Useful commands:"
echo "  View logs:     sudo docker logs ${CONTAINER_NAME}"
echo "  Follow logs:   sudo docker logs -f ${CONTAINER_NAME}"
echo "  Restart:       sudo docker restart ${CONTAINER_NAME}"
echo "  Stop:          sudo docker stop ${CONTAINER_NAME}"
echo "  Status:        sudo docker ps -a | grep ${CONTAINER_NAME}"
echo ""
echo "Access the application at:"
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "YOUR_EC2_IP")
echo "  http://${INSTANCE_IP}:${HOST_PORT}"
echo ""


