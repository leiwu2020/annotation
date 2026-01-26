# EC2 Deployment Guide for Annotation App

This guide provides step-by-step instructions for deploying the Annotation App Docker image from ECR to an Amazon EC2 instance.

## Prerequisites

### EC2 Instance Requirements
- **Instance Type**: t3.small or larger (minimum 1GB RAM)
- **Operating System**: Ubuntu 20.04 LTS or Amazon Linux 2
- **Storage**: At least 10GB free space
- **Security Group**: Allow inbound traffic on port 5000 (or your chosen port)

### AWS Permissions
Your EC2 instance needs the following IAM permissions:
```json
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
        }
    ]
}
```

## Deployment Scripts

### 1. Initial Deployment (`deploy-to-ec2.sh`)

This script performs a complete deployment from scratch:

```bash
# Basic deployment (uses latest image on port 5000)
sudo ./deploy-to-ec2.sh

# Deploy specific version
sudo ./deploy-to-ec2.sh v1.0.0

# Deploy with custom ports
sudo ./deploy-to-ec2.sh latest 5000 8080
```

**What the script does:**
- ✅ Checks Docker installation and installs if needed
- ✅ Installs AWS CLI if not present
- ✅ Authenticates with ECR
- ✅ Creates necessary directories (`/opt/annotation-app/`)
- ✅ Pulls the Docker image from ECR
- ✅ Stops and removes any existing containers
- ✅ Deploys the container with proper configuration
- ✅ Sets up systemd service for auto-start
- ✅ Configures firewall rules
- ✅ Waits for health checks

### 2. Update Deployment (`update-deployment.sh`)

This script updates an existing deployment with a new image:

```bash
# Update to latest image
sudo ./update-deployment.sh

# Update to specific version
sudo ./update-deployment.sh v1.1.0
```

## Manual Deployment Steps

If you prefer to deploy manually or need to troubleshoot:

### 1. Connect to Your EC2 Instance
```bash
ssh -i your-key.pem ubuntu@your-ec2-ip
```

### 2. Install Docker
```bash
# Update package index
sudo apt update

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add your user to docker group
sudo usermod -aG docker $USER

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Log out and back in for group changes to take effect
```

### 3. Install AWS CLI
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
```

### 4. Configure AWS Credentials
```bash
aws configure
# Enter your AWS Access Key ID, Secret Access Key, and region (us-east-1)
```

### 5. Authenticate with ECR
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com
```

### 6. Create Application Directories
```bash
sudo mkdir -p /opt/annotation-app/{uploads,instance,logs}
sudo chown -R 1000:1000 /opt/annotation-app
```

### 7. Pull and Run the Container
```bash
# Pull the image
docker pull 517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest

# Run the container
docker run -d \
  --name annotation-app \
  --restart unless-stopped \
  -p 5000:5000 \
  -v /opt/annotation-app/uploads:/app/uploads \
  -v /opt/annotation-app/instance:/app/instance \
  -v /opt/annotation-app/logs:/app/logs \
  517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app:latest
```

## Configuration

### Environment Variables
The container supports the following environment variables:
- `FLASK_ENV`: Set to `production` for production deployment
- `PYTHONUNBUFFERED`: Set to `1` for real-time logging

### Volumes
- `/app/uploads`: File uploads directory
- `/app/instance`: SQLite database files
- `/app/logs`: Application logs

### Ports
- **Container Port**: 5000 (internal Flask port)
- **Host Port**: 5000 (configurable, external access port)

## Management Commands

### Container Management
```bash
# View container status
sudo docker ps

# View logs
sudo docker logs annotation-app

# Follow logs in real-time
sudo docker logs -f annotation-app

# Stop container
sudo docker stop annotation-app

# Start container
sudo docker start annotation-app

# Restart container
sudo docker restart annotation-app

# Access container shell
sudo docker exec -it annotation-app /bin/bash
```

### Systemd Service Management
```bash
# Start service
sudo systemctl start annotation-app

# Stop service
sudo systemctl stop annotation-app

# Restart service
sudo systemctl restart annotation-app

# Check service status
sudo systemctl status annotation-app

# Enable auto-start
sudo systemctl enable annotation-app
```

### Docker Compose Management
```bash
cd /opt/annotation-app

# Start services
sudo docker-compose up -d

# Stop services
sudo docker-compose down

# View logs
sudo docker-compose logs

# Restart services
sudo docker-compose restart
```

## Monitoring and Troubleshooting

### Health Checks
The container includes built-in health checks:
```bash
# Check container health
sudo docker inspect annotation-app | grep -A 10 Health

# Manual health check
curl http://localhost:5000/health
```

### Log Analysis
```bash
# View application logs
sudo docker logs annotation-app --tail 50

# View system logs
sudo journalctl -u annotation-app -f

# Check Docker daemon logs
sudo journalctl -u docker -f
```

### Common Issues

#### Container Won't Start
```bash
# Check container logs
sudo docker logs annotation-app

# Check if port is already in use
sudo netstat -tulpn | grep :5000

# Check disk space
df -h
```

#### ECR Authentication Issues
```bash
# Re-authenticate with ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com

# Check AWS credentials
aws sts get-caller-identity
```

#### Permission Issues
```bash
# Fix directory permissions
sudo chown -R 1000:1000 /opt/annotation-app

# Check Docker daemon
sudo systemctl status docker
```

## Security Considerations

### Firewall Configuration
```bash
# Ubuntu/Debian (UFW)
sudo ufw allow 5000/tcp
sudo ufw enable

# CentOS/RHEL (firewalld)
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload
```

### SSL/HTTPS Setup
For production, consider using a reverse proxy like Nginx with SSL:
```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;
    
    ssl_certificate /path/to/certificate.crt;
    ssl_certificate_key /path/to/private.key;
    
    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Backup and Recovery

### Database Backup
```bash
# Create backup
sudo cp /opt/annotation-app/instance/annotation.db /opt/annotation-app/backups/annotation-$(date +%Y%m%d).db

# Restore from backup
sudo cp /opt/annotation-app/backups/annotation-20240101.db /opt/annotation-app/instance/annotation.db
sudo docker restart annotation-app
```

### Full Application Backup
```bash
# Create backup directory
sudo mkdir -p /opt/backups

# Backup application data
sudo tar -czf /opt/backups/annotation-app-$(date +%Y%m%d).tar.gz /opt/annotation-app

# Restore from backup
sudo tar -xzf /opt/backups/annotation-app-20240101.tar.gz -C /
```

## Scaling and Load Balancing

For high-traffic deployments, consider:
- Using AWS Application Load Balancer
- Running multiple container instances
- Using AWS ECS or EKS for orchestration
- Implementing database clustering

## Support

If you encounter issues:
1. Check the container logs: `sudo docker logs annotation-app`
2. Verify the health endpoint: `curl http://localhost:5000/health`
3. Check system resources: `top`, `df -h`, `free -m`
4. Review the deployment logs for any errors

The application is now ready for production use! 🚀









