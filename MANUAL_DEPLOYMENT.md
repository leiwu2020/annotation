# Manual Deployment Guide for image-annotation-app on EC2

This guide provides step-by-step instructions for manually deploying the image-annotation-app to an EC2 instance.

## Prerequisites

1. EC2 instance running (Amazon Linux 2 or Ubuntu)
2. SSH access to the EC2 instance
3. AWS credentials configured (IAM role or AWS profile)
4. Docker image pushed to ECR: `517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest`

## Step 1: SSH into EC2 Instance

```bash
ssh -i your-key.pem ec2-user@YOUR_EC2_IP
# For Ubuntu, use: ssh -i your-key.pem ubuntu@YOUR_EC2_IP
```

## Step 2: Install Docker

### For Amazon Linux 2:
```bash
sudo yum update -y
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER
# Log out and log back in for group changes to take effect
```

### For Ubuntu:
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
sudo systemctl start docker
sudo systemctl enable docker
# Log out and log back in for group changes to take effect
```

## Step 3: Install AWS CLI

```bash
# For Amazon Linux 2
sudo yum install -y aws-cli

# For Ubuntu or if yum doesn't work
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
```

## Step 4: Configure AWS Credentials

### Option A: Using IAM Role (Recommended)
1. Attach an IAM role to your EC2 instance with ECR permissions
2. The instance will automatically use the IAM role credentials

### Option B: Using AWS Profile
1. Copy your AWS config and credentials to the instance:
   ```bash
   # On your local machine
   scp -i your-key.pem ~/.aws/config ec2-user@YOUR_EC2_IP:~/.aws/config
   scp -i your-key.pem ~/.aws/credentials ec2-user@YOUR_EC2_IP:~/.aws/credentials
   ```

2. On the EC2 instance, set permissions:
   ```bash
   chmod 600 ~/.aws/config ~/.aws/credentials
   chmod 700 ~/.aws
   ```

## Step 5: Authenticate with ECR

```bash
# Using IAM role (if attached)
aws ecr get-login-password --region us-east-1 | sudo docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com

# OR using AWS profile
aws ecr get-login-password --region us-east-1 --profile YOUR_PROFILE | sudo docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com
```

## Step 6: Create Required Directories

```bash
sudo mkdir -p /opt/image-annotation-app/{uploads,instance,logs}
sudo chown -R 1000:1000 /opt/image-annotation-app
```

## Step 7: Stop and Remove Existing Container (if any)

```bash
sudo docker stop image-annotation-app 2>/dev/null || true
sudo docker rm image-annotation-app 2>/dev/null || true
```

## Step 8: Pull and Run the Docker Container

### Basic Run (without AWS profile):
```bash
sudo docker pull 517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest

sudo docker run -d \
    --name image-annotation-app \
    --restart unless-stopped \
    -p 5000:5000 \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1 \
    517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest
```

### With AWS Profile (if you copied AWS config):
```bash
# First, get the absolute path to .aws directory
AWS_DIR=$(cd ~/.aws && pwd)

sudo docker pull 517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest

sudo docker run -d \
    --name image-annotation-app \
    --restart unless-stopped \
    -p 5000:5000 \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -v ${AWS_DIR}:/root/.aws:ro \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1 \
    -e AWS_PROFILE=YOUR_PROFILE \
    517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest
```

## Step 9: Verify Deployment

```bash
# Check if container is running
sudo docker ps

# Check container logs
sudo docker logs image-annotation-app

# Follow logs in real-time
sudo docker logs -f image-annotation-app

# Test the application
curl http://localhost:5000
```

## Step 10: Access the Application

Open your browser and navigate to:
```
http://YOUR_EC2_PUBLIC_IP:5000
```

Make sure your EC2 security group allows inbound traffic on port 5000.

## Useful Commands

### View Container Status
```bash
sudo docker ps -a
```

### View Container Logs
```bash
sudo docker logs image-annotation-app
sudo docker logs -f image-annotation-app  # Follow logs
sudo docker logs --tail 100 image-annotation-app  # Last 100 lines
```

### Restart Container
```bash
sudo docker restart image-annotation-app
```

### Stop Container
```bash
sudo docker stop image-annotation-app
```

### Start Container
```bash
sudo docker start image-annotation-app
```

### Remove Container
```bash
sudo docker stop image-annotation-app
sudo docker rm image-annotation-app
```

### Update to New Image
```bash
# Pull latest image
sudo docker pull 517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest

# Stop and remove old container
sudo docker stop image-annotation-app
sudo docker rm image-annotation-app

# Run new container (use the same docker run command from Step 8)
```

### Execute Commands in Container
```bash
sudo docker exec -it image-annotation-app bash
```

## Troubleshooting

### Container won't start
```bash
# Check logs
sudo docker logs image-annotation-app

# Check if port is already in use
sudo netstat -tulpn | grep 5000
```

### ECR Authentication Failed
```bash
# Verify AWS credentials
aws sts get-caller-identity

# Re-authenticate with ECR
aws ecr get-login-password --region us-east-1 | sudo docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com
```

### Permission Denied Errors
```bash
# Fix directory permissions
sudo chown -R 1000:1000 /opt/image-annotation-app
sudo chmod -R 755 /opt/image-annotation-app
```

### Application Not Accessible
1. Check security group allows port 5000
2. Check container is running: `sudo docker ps`
3. Check container logs: `sudo docker logs image-annotation-app`
4. Verify firewall rules: `sudo iptables -L`

## Environment Variables

You can customize the deployment by setting environment variables:

```bash
sudo docker run -d \
    --name image-annotation-app \
    --restart unless-stopped \
    -p 5000:5000 \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1 \
    -e AWS_PROFILE=your-profile \
    -e AWS_VERIFY_SSL=true \
    517569678285.dkr.ecr.us-east-1.amazonaws.com/image-annotation-app:latest
```

## Security Notes

1. **Use IAM Roles**: Prefer IAM roles over copying credentials
2. **Secure Ports**: Only open necessary ports in security groups
3. **Regular Updates**: Keep Docker and the application image updated
4. **Backup Data**: Regularly backup `/opt/image-annotation-app` directory
5. **Monitor Logs**: Regularly check container logs for errors


