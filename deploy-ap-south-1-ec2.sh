#!/bin/bash
# Deploy Annotation App to EC2 in ap-south-1 region

set -e

REGION="ap-south-1"
INSTANCE_TYPE="t3.small"
KEY_NAME="annotation-key-mumbai"
KEY_FILE="annotation-key-mumbai.pem"
IMAGE_ID="ami-0c55b159cbfafe1f0"  # Amazon Linux 2023 AMI for ap-south-1
SECURITY_GROUP_NAME="annotation-app-sg-ap-south-1"
ECR_REGISTRY="517569678285.dkr.ecr.ap-south-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
IMAGE_TAG="latest"

echo "=========================================="
echo "  Deploy Annotation App to EC2"
echo "  Region: $REGION"
echo "  Instance Type: $INSTANCE_TYPE"
echo "=========================================="
echo ""

# Check if key file exists
if [ ! -f "$KEY_FILE" ]; then
    echo "Error: Key file $KEY_FILE not found"
    exit 1
fi

chmod 400 $KEY_FILE

# Get default VPC
echo "Step 1: Getting default VPC..."
VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    echo "Error: No default VPC found in $REGION"
    exit 1
fi
echo "✓ Found VPC: $VPC_ID"

# Create or get security group
echo ""
echo "Step 2: Setting up security group..."
SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    echo "Creating security group..."
    SG_ID=$(aws ec2 create-security-group --region $REGION \
        --group-name $SECURITY_GROUP_NAME \
        --description "Security group for Annotation App" \
        --vpc-id $VPC_ID \
        --query 'GroupId' --output text)
    echo "✓ Created security group: $SG_ID"
    
    # Add SSH rule
    aws ec2 authorize-security-group-ingress --region $REGION \
        --group-id $SG_ID \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 2>/dev/null || echo "SSH rule may already exist"
    
    # Add HTTP rule for port 5000
    aws ec2 authorize-security-group-ingress --region $REGION \
        --group-id $SG_ID \
        --protocol tcp \
        --port 5000 \
        --cidr 0.0.0.0/0 2>/dev/null || echo "Port 5000 rule may already exist"
    
    echo "✓ Security group rules configured"
else
    echo "✓ Using existing security group: $SG_ID"
fi

# Check if ECR repository exists in ap-south-1, if not, create it
echo ""
echo "Step 3: Checking ECR repository..."
aws ecr describe-repositories --region $REGION --repository-names $ECR_REPOSITORY >/dev/null 2>&1 || \
    aws ecr create-repository --region $REGION --repository-name $ECR_REPOSITORY >/dev/null 2>&1
echo "✓ ECR repository ready"

# Create EC2 instance
echo ""
echo "Step 4: Creating EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $IMAGE_ID \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $SG_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=annotation-app-ap-south-1}]" \
    --query 'Instances[0].InstanceId' --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "Error: Failed to create EC2 instance"
    exit 1
fi

echo "✓ Instance created: $INSTANCE_ID"
echo "Waiting for instance to be running..."

# Wait for instance to be running
aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_ID
echo "✓ Instance is running"

# Get public IP
echo ""
echo "Step 5: Getting instance details..."
sleep 5
PUBLIC_IP=$(aws ec2 describe-instances --region $REGION \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "Warning: Public IP not yet assigned, waiting..."
    sleep 10
    PUBLIC_IP=$(aws ec2 describe-instances --region $REGION \
        --instance-ids $INSTANCE_ID \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
fi

echo "✓ Public IP: $PUBLIC_IP"

# Wait for SSH to be ready
echo ""
echo "Step 6: Waiting for SSH to be ready..."
for i in {1..30}; do
    if ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ec2-user@$PUBLIC_IP "echo 'SSH ready'" 2>/dev/null; then
        echo "✓ SSH is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Warning: SSH not ready after 30 attempts, continuing anyway..."
    else
        sleep 2
    fi
done

# Copy deployment script to instance
echo ""
echo "Step 7: Copying deployment script to instance..."
scp -i $KEY_FILE -o StrictHostKeyChecking=no deploy-to-ec2-interactive.sh ec2-user@$PUBLIC_IP:/tmp/ 2>&1 | tail -3

# Note: The image needs to be in ap-south-1 ECR or we need to copy from us-east-1
echo ""
echo "=========================================="
echo "  Instance Created Successfully!"
echo "=========================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Region: $REGION"
echo ""
echo "Next steps:"
echo "1. Ensure the Docker image is available in ECR ($REGION)"
echo "2. SSH to the instance:"
echo "   ssh -i $KEY_FILE ec2-user@$PUBLIC_IP"
echo ""
echo "3. Run the deployment script:"
echo "   sudo bash /tmp/deploy-to-ec2-interactive.sh latest 5000 5000"
echo ""
echo "Note: Update ECR_REGISTRY in deploy-to-ec2-interactive.sh to use ap-south-1 registry"
echo ""

