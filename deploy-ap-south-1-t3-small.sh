#!/bin/bash
set -e

# --- BUILD TARBALL ---
echo "Building app tarball..."
TARBALL_NAME="annotation-app-$(date +%Y%m%d_%H%M%S).tar.gz"
tar --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.tar.gz' \
    -czvf "$TARBALL_NAME" \
    app.py requirements.txt users.db \
    templates static uploads instance
TARBALL="$TARBALL_NAME"
echo "Tarball created: $TARBALL"

# --- CONFIG ---
KEY_NAME="annotation-key-mumbai"
KEY_PATH="annotation-key-mumbai.pem"
REGION="ap-south-1"
AMI_ID="ami-0f5ee92e2d63afc18" # Ubuntu 22.04 LTS (update if needed)
INSTANCE_TYPE="t3.small"
SECURITY_GROUP="annotation-sg-mumbai"
SECURITY_GROUP_ID="sg-0875158a71c0d9b03"
IAM_ROLE="AnnotationAppEC2Role"
VPC_ID="vpc-00591c1ebb0cb71de"
SUBNET_ID="subnet-08dff09b9f50eb1dd"
AVAILABILITY_ZONE="ap-south-1c"
APP_PORT=5000

# --- LAUNCH EC2 ---
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --iam-instance-profile Name=$IAM_ROLE \
    --subnet-id $SUBNET_ID \
    --placement AvailabilityZone=$AVAILABILITY_ZONE \
    --region $REGION \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# --- GET PUBLIC IP ---
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "EC2 Public IP: $PUBLIC_IP"

# --- COPY FILES ---
echo "Copying tarball to EC2..."
scp -i $KEY_PATH -o StrictHostKeyChecking=no $TARBALL ubuntu@$PUBLIC_IP:~

# --- REMOTE SETUP ---
echo "Setting up app on EC2..."
ssh -i $KEY_PATH -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP << 'EOF'
set -e
sudo apt update
sudo apt install -y python3-pip python3-venv
tar -xzvf annotation-app-*.tar.gz
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
nohup venv/bin/python app.py --HOST=0.0.0.0 --PORT=5000 > app.log 2>&1 &
echo "App started. Check app.log for details."
EOF

echo "Deployment complete. Access your app at: http://$PUBLIC_IP:$APP_PORT"