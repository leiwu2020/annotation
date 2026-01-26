#!/bin/bash

# Launch EC2 Instance and Deploy Annotation App
# This script launches an EC2 instance and deploys the annotation application

set -e

# Configuration
KEY_NAME="annotation-key"
SECURITY_GROUP_NAME="annotation-sg"
INSTANCE_TYPE="t3.small"
AMI_ID="ami-0c02fb55956c7d316"  # Ubuntu 22.04 LTS (us-east-1)
REGION="us-east-1"
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"

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

# Create key pair if it doesn't exist
create_key_pair() {
    log "Checking for SSH key pair..."
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
        success "Key pair '$KEY_NAME' already exists"
    else
        log "Creating SSH key pair..."
        aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
        chmod 600 "${KEY_NAME}.pem"
        success "Key pair '$KEY_NAME' created and saved to ${KEY_NAME}.pem"
    fi
}

# Create security group if it doesn't exist
create_security_group() {
    log "Checking for security group..."
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [ "$SECURITY_GROUP_ID" = "None" ] || [ "$SECURITY_GROUP_ID" = "null" ]; then
        log "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Security group for annotation app" --region "$REGION" --query 'GroupId' --output text)
        
        # Allow SSH access
        aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION"
        
        # Allow HTTP access for the application
        aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 5000 --cidr 0.0.0.0/0 --region "$REGION"
        
        success "Security group '$SECURITY_GROUP_NAME' created with ID: $SECURITY_GROUP_ID"
    else
        success "Security group '$SECURITY_GROUP_NAME' already exists with ID: $SECURITY_GROUP_ID"
    fi
}

# Launch EC2 instance
launch_instance() {
    log "Launching EC2 instance..."
    
    # Create user data script for initial setup
    cat > user-data.sh << 'EOF'
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
mkdir -p /opt/annotation-app/{uploads,instance,logs}
chown -R 1000:1000 /opt/annotation-app
EOF

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --user-data file://user-data.sh \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=annotation-app}]' \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    success "EC2 instance launched with ID: $INSTANCE_ID"
    
    # Wait for instance to be running
    log "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    
    success "Instance is running with public IP: $PUBLIC_IP"
    
    # Wait a bit more for user data to complete
    log "Waiting for instance initialization to complete..."
    sleep 60
    
    echo "$PUBLIC_IP"
}

# Deploy application to EC2
deploy_to_instance() {
    local PUBLIC_IP="$1"
    
    log "Deploying application to instance $PUBLIC_IP..."
    
    # Copy deployment script to instance
    scp -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no deploy-to-ec2-interactive.sh ubuntu@$PUBLIC_IP:~/
    
    # Copy validation script to instance
    scp -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no validate-deployment.sh ubuntu@$PUBLIC_IP:~/
    
    # Make scripts executable
    ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP "chmod +x ~/deploy-to-ec2-interactive.sh ~/validate-deployment.sh"
    
    # Run deployment script
    log "Running deployment script on instance..."
    ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP "./deploy-to-ec2-interactive.sh"
    
    # Validate deployment
    log "Validating deployment..."
    ssh -i "${KEY_NAME}.pem" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP "./validate-deployment.sh"
    
    success "Application deployed successfully!"
}

# Show final information
show_final_info() {
    local PUBLIC_IP="$1"
    
    echo ""
    echo "=========================================="
    success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    echo "=========================================="
    echo ""
    echo "Instance Information:"
    echo "  Instance ID: $INSTANCE_ID"
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
    echo "  View logs: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker logs annotation-app'"
    echo "  Restart app: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker restart annotation-app'"
    echo "  Stop app: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker stop annotation-app'"
    echo ""
    echo "Cleanup (when done):"
    echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
    echo "  aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION"
    echo "  aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  EC2 Instance Launch and Deployment"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  AMI: $AMI_ID (Ubuntu 22.04 LTS)"
    echo "  Region: $REGION"
    echo "  ECR Registry: $ECR_REGISTRY"
    echo ""
    
    # Run deployment steps
    create_key_pair
    create_security_group
    PUBLIC_IP=$(launch_instance)
    deploy_to_instance "$PUBLIC_IP"
    show_final_info "$PUBLIC_IP"
    
    echo ""
    success "Complete deployment finished!"
    echo "Your annotation application is now running at: http://$PUBLIC_IP:5000"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo ""
        echo "This script will:"
        echo "1. Create SSH key pair if needed"
        echo "2. Create security group if needed"
        echo "3. Launch EC2 instance with Ubuntu 22.04"
        echo "4. Deploy annotation application from ECR"
        echo "5. Validate deployment"
        echo ""
        echo "Prerequisites:"
        echo "- AWS CLI configured with appropriate permissions"
        echo "- ECR repository with annotation-app image"
        echo ""
        exit 0
        ;;
    *)
        main
        ;;
esac









