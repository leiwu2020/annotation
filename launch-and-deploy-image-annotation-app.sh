#!/bin/bash

# Launch EC2 t3.small Instance and Deploy image-annotation-app
# This script launches an EC2 instance and deploys the image-annotation-app

set -e

# Configuration
KEY_NAME="image-annotation-app-key"
SECURITY_GROUP_NAME="image-annotation-app-sg"
INSTANCE_TYPE="t3.small"
AMI_ID="ami-0c02fb55956c7d316"  # Ubuntu 22.04 LTS (us-east-1)
REGION="us-east-1"
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="image-annotation-app"
IMAGE_TAG="${1:-latest}"
AWS_PROFILE="${AWS_PROFILE:-default}"

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

# Check AWS CLI
check_aws_cli() {
    log "Checking AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    success "AWS CLI is installed"
}

# Check AWS SSO login
check_aws_sso() {
    log "Checking AWS SSO login status for profile: ${AWS_PROFILE}..."
    
    if ! aws sts get-caller-identity --profile ${AWS_PROFILE} > /dev/null 2>&1; then
        warning "AWS SSO session expired or invalid"
        log "Attempting AWS SSO login..."
        
        if aws sso login --profile ${AWS_PROFILE}; then
            success "AWS SSO login successful"
        else
            error "AWS SSO login failed"
            echo "Please run manually: aws sso login --profile ${AWS_PROFILE}"
            exit 1
        fi
    else
        success "AWS SSO session is valid"
    fi
}

# Create key pair if it doesn't exist
create_key_pair() {
    log "Checking for SSH key pair..."
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" --profile ${AWS_PROFILE} &>/dev/null; then
        success "Key pair '$KEY_NAME' already exists"
        if [ ! -f "${KEY_NAME}.pem" ]; then
            warning "Key file ${KEY_NAME}.pem not found locally. You may need to download it from AWS."
        fi
    else
        log "Creating SSH key pair..."
        aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --profile ${AWS_PROFILE} --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
        chmod 600 "${KEY_NAME}.pem"
        success "Key pair '$KEY_NAME' created and saved to ${KEY_NAME}.pem"
    fi
}

# Create security group if it doesn't exist
create_security_group() {
    log "Checking for security group..."
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$REGION" --profile ${AWS_PROFILE} --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [ "$SECURITY_GROUP_ID" = "None" ] || [ "$SECURITY_GROUP_ID" = "null" ]; then
        log "Creating security group..."
        VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --profile ${AWS_PROFILE} --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
        SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Security group for image-annotation-app" --vpc-id "$VPC_ID" --region "$REGION" --profile ${AWS_PROFILE} --query 'GroupId' --output text)
        
        # Allow SSH access
        aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION" --profile ${AWS_PROFILE} 2>/dev/null || true
        
        # Allow HTTP access for the application
        aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 5000 --cidr 0.0.0.0/0 --region "$REGION" --profile ${AWS_PROFILE} 2>/dev/null || true
        
        success "Security group '$SECURITY_GROUP_NAME' created with ID: $SECURITY_GROUP_ID"
    else
        success "Security group '$SECURITY_GROUP_NAME' already exists with ID: $SECURITY_GROUP_ID"
    fi
}

# Launch EC2 instance
launch_instance() {
    log "Launching EC2 ${INSTANCE_TYPE} instance in ${REGION}..."
    
    # Create user data script for initial setup
    cat > /tmp/user-data-image-annotation-app.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y docker.io awscli curl unzip
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Install docker-compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create application directory
mkdir -p /opt/image-annotation-app/{uploads,instance,logs}
chown -R 1000:1000 /opt/image-annotation-app
EOF

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --user-data file:///tmp/user-data-image-annotation-app.sh \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=image-annotation-app}]" \
        --region "$REGION" \
        --profile ${AWS_PROFILE} \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    success "EC2 instance launched with ID: $INSTANCE_ID"
    
    # Wait for instance to be running
    log "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION" --profile ${AWS_PROFILE}
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --profile ${AWS_PROFILE} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    
    success "Instance is running with public IP: $PUBLIC_IP"
    
    # Wait a bit more for user data to complete
    log "Waiting for instance initialization to complete (this may take 1-2 minutes)..."
    sleep 90
    
    echo "$INSTANCE_ID|$PUBLIC_IP"
}

# Deploy application to EC2
deploy_to_instance() {
    local INSTANCE_ID="$1"
    local PUBLIC_IP="$2"
    
    log "Deploying image-annotation-app to instance $PUBLIC_IP..."
    
    # Create deployment script
    cat > /tmp/deploy-image-annotation-app-remote.sh << DEPLOYSCRIPT
#!/bin/bash
set -e

ECR_REGISTRY="${ECR_REGISTRY}"
ECR_REPOSITORY="${ECR_REPOSITORY}"
IMAGE_TAG="${IMAGE_TAG}"
CONTAINER_NAME="image-annotation-app"
APP_PORT=5000
HOST_PORT=5000

echo "Starting deployment..."

# Wait for Docker to be ready
while ! docker info > /dev/null 2>&1; do
    echo "Waiting for Docker..."
    sleep 5
done

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi

# Authenticate with ECR
echo "Authenticating with ECR..."
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin \${ECR_REGISTRY}

# Create directories
sudo mkdir -p /opt/image-annotation-app/{uploads,instance,logs}
sudo chown -R 1000:1000 /opt/image-annotation-app

# Stop and remove existing container
sudo docker stop \${CONTAINER_NAME} 2>/dev/null || true
sudo docker rm \${CONTAINER_NAME} 2>/dev/null || true

# Pull and run container
echo "Pulling image..."
sudo docker pull \${ECR_REGISTRY}/\${ECR_REPOSITORY}:\${IMAGE_TAG}

echo "Starting container..."
sudo docker run -d \
    --name \${CONTAINER_NAME} \
    --restart unless-stopped \
    -p \${HOST_PORT}:\${APP_PORT} \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1 \
    \${ECR_REGISTRY}/\${ECR_REPOSITORY}:\${IMAGE_TAG}

echo "Waiting for container to start..."
sleep 10

# Check if container is running
if sudo docker ps | grep -q \${CONTAINER_NAME}; then
    echo "SUCCESS: Container is running!"
    sudo docker ps | grep \${CONTAINER_NAME}
else
    echo "ERROR: Container failed to start"
    sudo docker logs \${CONTAINER_NAME}
    exit 1
fi
DEPLOYSCRIPT

    # Copy deployment script to instance
    log "Copying deployment script to instance..."
    if [ -f "${KEY_NAME}.pem" ]; then
        scp -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=10 /tmp/deploy-image-annotation-app-remote.sh ubuntu@$PUBLIC_IP:~/deploy.sh
        
        # Make script executable and run it
        log "Running deployment script on instance..."
        ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$PUBLIC_IP "chmod +x ~/deploy.sh && ~/deploy.sh"
        
        success "Application deployed successfully!"
    else
        warning "SSH key file ${KEY_NAME}.pem not found. Cannot deploy automatically."
        echo "Please manually SSH into the instance and run the deployment script."
        echo "SSH command: ssh -i ${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
        echo "The deployment script is saved at: /tmp/deploy-image-annotation-app-remote.sh"
    fi
}

# Show final information
show_final_info() {
    local INSTANCE_ID="$1"
    local PUBLIC_IP="$2"
    
    echo ""
    echo "=========================================="
    success "DEPLOYMENT COMPLETED!"
    echo "=========================================="
    echo ""
    echo "Instance Information:"
    echo "  Instance ID: $INSTANCE_ID"
    echo "  Instance Type: ${INSTANCE_TYPE}"
    echo "  Public IP: $PUBLIC_IP"
    echo "  Region: $REGION"
    echo ""
    echo "Application Access:"
    echo "  Web Interface: http://$PUBLIC_IP:5000"
    echo ""
    echo "SSH Access:"
    echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
    echo ""
    echo "Management Commands:"
    echo "  View logs: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker logs image-annotation-app'"
    echo "  Restart app: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker restart image-annotation-app'"
    echo "  Stop app: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker stop image-annotation-app'"
    echo ""
    echo "Cleanup (when done):"
    echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION --profile ${AWS_PROFILE}"
    echo "  aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION --profile ${AWS_PROFILE}"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  Launch EC2 and Deploy image-annotation-app"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  AMI: $AMI_ID (Ubuntu 22.04 LTS)"
    echo "  Region: $REGION"
    echo "  ECR Registry: $ECR_REGISTRY"
    echo "  Repository: $ECR_REPOSITORY"
    echo "  Image Tag: $IMAGE_TAG"
    echo "  AWS Profile: $AWS_PROFILE"
    echo ""
    
    # Run deployment steps
    check_aws_cli
    check_aws_sso
    create_key_pair
    create_security_group
    INSTANCE_INFO=$(launch_instance)
    INSTANCE_ID=$(echo $INSTANCE_INFO | cut -d'|' -f1)
    PUBLIC_IP=$(echo $INSTANCE_INFO | cut -d'|' -f2)
    deploy_to_instance "$INSTANCE_ID" "$PUBLIC_IP"
    show_final_info "$INSTANCE_ID" "$PUBLIC_IP"
    
    echo ""
    success "Complete deployment finished!"
    echo "Your image-annotation-app is now running at: http://$PUBLIC_IP:5000"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [IMAGE_TAG]"
        echo ""
        echo "This script will:"
        echo "1. Create SSH key pair if needed"
        echo "2. Create security group if needed"
        echo "3. Launch EC2 t3.small instance with Ubuntu 22.04 in us-east-1"
        echo "4. Deploy image-annotation-app from ECR"
        echo "5. Validate deployment"
        echo ""
        echo "Arguments:"
        echo "  IMAGE_TAG    Docker image tag (default: latest)"
        echo ""
        echo "Environment Variables:"
        echo "  AWS_PROFILE  AWS profile to use (default: default)"
        echo ""
        echo "Prerequisites:"
        echo "- AWS CLI configured with appropriate permissions"
        echo "- ECR repository 'image-annotation-app' with image"
        echo ""
        exit 0
        ;;
    *)
        main
        ;;
esac

