#!/bin/bash

# Launch EC2 Instance and Deploy Annotation App in ap-south-1 (Mumbai)
# This script launches a t3.small EC2 instance in Mumbai and deploys the annotation application

set -e

# Configuration for ap-south-1 (Mumbai)
KEY_NAME="annotation-key-mumbai"
SECURITY_GROUP_NAME="annotation-sg-mumbai"
INSTANCE_TYPE="t3.small"
AMI_ID="ami-0f5ee92e2d63afc18"  # Ubuntu 22.04 LTS in ap-south-1
REGION="ap-south-1"
ECR_REGION="us-east-1"  # ECR registry is in us-east-1
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
IMAGE_TAG="${1:-latest}"

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
    log "Checking AWS CLI..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        echo "Installation: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Please run 'aws configure'"
        exit 1
    fi
    
    success "AWS CLI is configured"
}

# Create key pair if it doesn't exist
create_key_pair() {
    log "Checking for SSH key pair..."
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
        success "Key pair '$KEY_NAME' already exists"
        if [ ! -f "${KEY_NAME}.pem" ]; then
            warning "Key file ${KEY_NAME}.pem not found locally. You'll need it to SSH to the instance."
        fi
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
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
        log "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Security group for annotation app in Mumbai" \
            --region "$REGION" \
            --query 'GroupId' \
            --output text)
        
        # Allow SSH access
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        # Allow HTTP access for the application
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 5000 \
            --cidr 0.0.0.0/0 \
            --region "$REGION"
        
        success "Security group '$SECURITY_GROUP_NAME' created with ID: $SECURITY_GROUP_ID"
    else
        success "Security group '$SECURITY_GROUP_NAME' already exists with ID: $SECURITY_GROUP_ID"
    fi
}

# Create IAM instance profile for ECR access
create_iam_role() {
    log "Checking IAM role for EC2..."
    ROLE_NAME="AnnotationAppEC2Role"
    
    if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        log "Creating IAM role..."
        
        # Create trust policy
        cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
        
        # Create role
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document file:///tmp/ec2-trust-policy.json
        
        # Attach ECR policy
        cat > /tmp/ecr-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::eval-hop/*",
        "arn:aws:s3:::eval-hop"
      ]
    }
  ]
}
EOF
        
        aws iam put-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name "ECRandS3Access" \
            --policy-document file:///tmp/ecr-policy.json
        
        # Create instance profile
        aws iam create-instance-profile --instance-profile-name "$ROLE_NAME"
        
        # Add role to instance profile
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$ROLE_NAME" \
            --role-name "$ROLE_NAME"
        
        # Wait for IAM changes to propagate
        sleep 10
        
        success "IAM role created: $ROLE_NAME"
    else
        success "IAM role already exists: $ROLE_NAME"
    fi
    
    INSTANCE_PROFILE="$ROLE_NAME"
}

# Launch EC2 instance
launch_instance() {
    log "Launching EC2 t3.small instance in Mumbai (ap-south-1)..."
    
    # Create user data script for initial setup
    cat > /tmp/user-data.sh << EOF
#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y docker.io awscli curl unzip jq

# Start Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Install docker-compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create application directory
mkdir -p /opt/annotation-app/{uploads,instance,logs}
chown -R 1000:1000 /opt/annotation-app

# Configure AWS region for ECR
mkdir -p /home/ubuntu/.aws
cat > /home/ubuntu/.aws/config << 'AWSEOF'
[default]
region = ${ECR_REGION}
AWSEOF
chown -R ubuntu:ubuntu /home/ubuntu/.aws

# Wait for Docker to be ready
sleep 5

# Login to ECR and pull image
aws ecr get-login-password --region ${ECR_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}

# Pull the annotation app image
docker pull ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}

# Run the container
docker run -d \\
  --name annotation-app \\
  --restart unless-stopped \\
  -p 5000:5000 \\
  -e FLASK_ENV=production \\
  -e PYTHONUNBUFFERED=1 \\
  -e AWS_DEFAULT_REGION=ap-south-1 \\
  -v /opt/annotation-app/uploads:/app/uploads \\
  -v /opt/annotation-app/instance:/app/instance \\
  -v /opt/annotation-app/logs:/app/logs \\
  ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}

# Wait for container to be healthy
sleep 10

# Create systemd service for auto-restart
cat > /etc/systemd/system/annotation-app.service << 'SYSTEMDEOF'
[Unit]
Description=Annotation App Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start annotation-app
ExecStop=/usr/bin/docker stop annotation-app
Restart=always

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable annotation-app.service

echo "Deployment completed successfully!" > /var/log/user-data-complete.log
EOF

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --iam-instance-profile "Name=$INSTANCE_PROFILE" \
        --user-data file:///tmp/user-data.sh \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=annotation-app-mumbai},{Key=Environment,Value=production},{Key=Application,Value=annotation}]" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    success "EC2 instance launched with ID: $INSTANCE_ID"
    
    # Wait for instance to be running
    log "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    success "Instance is running with public IP: $PUBLIC_IP"
    
    # Wait for user data to complete
    log "Waiting for Docker image to be pulled and container to start (this may take 2-3 minutes)..."
    sleep 120
    
    echo "$PUBLIC_IP"
}

# Validate deployment
validate_deployment() {
    local PUBLIC_IP="$1"
    local MAX_RETRIES=30
    local RETRY_COUNT=0
    
    log "Validating deployment..."
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://$PUBLIC_IP:5000" | grep -q "200\|302\|301"; then
            success "Application is responding!"
            return 0
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Waiting for application to start... (attempt $RETRY_COUNT/$MAX_RETRIES)"
        sleep 10
    done
    
    warning "Application is not responding yet. You may need to check the logs."
    return 1
}

# Show final information
show_final_info() {
    local PUBLIC_IP="$1"
    
    echo ""
    echo "=========================================="
    success "DEPLOYMENT COMPLETED!"
    echo "=========================================="
    echo ""
    echo "Instance Information:"
    echo "  Instance ID: $INSTANCE_ID"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  Public IP: $PUBLIC_IP"
    echo "  Region: $REGION (Mumbai)"
    echo "  AMI: $AMI_ID (Ubuntu 22.04 LTS)"
    echo ""
    echo "Application Access:"
    echo "  Web Interface: http://$PUBLIC_IP:5000"
    echo "  Default Admin Login:"
    echo "    Username: admin"
    echo "    Password: admin0516"
    echo ""
    echo "SSH Access:"
    echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
    echo ""
    echo "Management Commands:"
    echo "  View logs:"
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker logs annotation-app'"
    echo ""
    echo "  Follow logs:"
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker logs -f annotation-app'"
    echo ""
    echo "  Restart application:"
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker restart annotation-app'"
    echo ""
    echo "  Stop application:"
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker stop annotation-app'"
    echo ""
    echo "  Check container status:"
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker ps'"
    echo ""
    echo "Cleanup Commands (when done):"
    echo "  Terminate instance:"
    echo "    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
    echo ""
    echo "  Delete security group (after instance is terminated):"
    echo "    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION"
    echo ""
    echo "  Delete key pair:"
    echo "    aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION"
    echo "    rm ${KEY_NAME}.pem"
    echo ""
    echo "Image Configuration:"
    echo "  To enable image viewing with S3:"
    echo "  1. Upload your annotation CSV file"
    echo "  2. Place 1669-v2_matched.csv in /opt/annotation-app/ on the server"
    echo "  3. Configure file to use '1669-v2_matched.csv' as image mapping"
    echo "  4. Ensure AWS credentials have S3 read access to eval-hop bucket"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  EC2 Deployment to Mumbai (ap-south-1)"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  AMI: $AMI_ID (Ubuntu 22.04 LTS)"
    echo "  Region: $REGION (Mumbai)"
    echo "  ECR Registry: $ECR_REGISTRY"
    echo "  Image Tag: $IMAGE_TAG"
    echo ""
    
    # Run deployment steps
    check_aws_cli
    create_key_pair
    create_security_group
    create_iam_role
    PUBLIC_IP=$(launch_instance)
    
    if validate_deployment "$PUBLIC_IP"; then
        show_final_info "$PUBLIC_IP"
        echo ""
        success "Deployment completed successfully!"
        echo "Access your application at: http://$PUBLIC_IP:5000"
    else
        warning "Deployment completed but application validation failed."
        echo "Please check the logs by running:"
        echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo docker logs annotation-app'"
        show_final_info "$PUBLIC_IP"
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [image-tag]"
        echo ""
        echo "Arguments:"
        echo "  image-tag  Docker image tag to deploy (default: latest)"
        echo ""
        echo "Examples:"
        echo "  $0              # Deploy latest image"
        echo "  $0 v1.0.0       # Deploy specific version"
        echo ""
        echo "This script will:"
        echo "1. Create SSH key pair if needed"
        echo "2. Create security group with ports 22 and 5000 open"
        echo "3. Create IAM role for ECR and S3 access"
        echo "4. Launch t3.small EC2 instance in ap-south-1 (Mumbai)"
        echo "5. Install Docker and dependencies"
        echo "6. Pull and run annotation application from ECR"
        echo "7. Configure auto-start on boot"
        echo "8. Validate deployment"
        echo ""
        echo "Prerequisites:"
        echo "- AWS CLI configured with appropriate permissions"
        echo "- ECR repository with annotation-app image in us-east-1"
        echo "- AWS credentials with EC2, IAM, and ECR permissions"
        echo ""
        exit 0
        ;;
    latest)
        main
        ;;
    *)
        if [ -n "${1:-}" ]; then
            IMAGE_TAG="$1"
        fi
        main
        ;;
esac



