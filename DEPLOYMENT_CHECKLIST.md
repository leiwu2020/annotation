# EC2 Deployment Checklist

## Pre-Deployment Checklist

### EC2 Instance Setup
- [ ] EC2 instance launched (t3.small or larger)
- [ ] Security group configured (port 5000 open)
- [ ] SSH access configured
- [ ] IAM role attached (ECR permissions)
- [ ] Instance has at least 10GB free space

### AWS Configuration
- [ ] AWS CLI installed on EC2 instance
- [ ] AWS credentials configured
- [ ] ECR repository exists (`517569678285.dkr.ecr.us-east-1.amazonaws.com/annotation-app`)
- [ ] Docker image pushed to ECR

## Deployment Process

### Option 1: Automated Deployment (Recommended)
```bash
# 1. Copy deployment script to EC2
scp -i your-key.pem deploy-to-ec2.sh ubuntu@your-ec2-ip:~/

# 2. SSH to EC2 instance
ssh -i your-key.pem ubuntu@your-ec2-ip

# 3. Run deployment script
sudo ./deploy-to-ec2.sh

# 4. Validate deployment
./validate-deployment.sh
```

### Option 2: Manual Deployment
- [ ] Install Docker
- [ ] Install AWS CLI
- [ ] Configure AWS credentials
- [ ] Authenticate with ECR
- [ ] Create application directories
- [ ] Pull and run Docker container
- [ ] Configure systemd service
- [ ] Setup firewall rules

## Post-Deployment Verification

### Basic Functionality Tests
- [ ] Application accessible via web browser
- [ ] Login page loads correctly
- [ ] User registration works
- [ ] File upload functionality works
- [ ] Annotation interface displays properly
- [ ] Multi-choice columns fit within page
- [ ] Dropdown menus fit within text areas
- [ ] Column visibility settings work

### System Health Checks
- [ ] Container is running and healthy
- [ ] Database files created in `/opt/annotation-app/instance/`
- [ ] Upload directory writable at `/opt/annotation-app/uploads/`
- [ ] Logs directory writable at `/opt/annotation-app/logs/`
- [ ] Systemd service enabled and running
- [ ] Firewall rules configured correctly

### Performance Tests
- [ ] Application responds quickly (< 2 seconds)
- [ ] Multiple users can access simultaneously
- [ ] File uploads work for large CSV files
- [ ] Database operations perform well
- [ ] Memory usage is reasonable (< 1GB)

## Troubleshooting Common Issues

### Container Issues
- [ ] Check container logs: `sudo docker logs annotation-app`
- [ ] Verify container status: `sudo docker ps`
- [ ] Restart container if needed: `sudo docker restart annotation-app`

### Network Issues
- [ ] Verify security group allows port 5000
- [ ] Check if port is accessible: `netstat -tulpn | grep :5000`
- [ ] Test local access: `curl http://localhost:5000`

### Permission Issues
- [ ] Fix directory permissions: `sudo chown -R 1000:1000 /opt/annotation-app`
- [ ] Check Docker daemon: `sudo systemctl status docker`

### ECR Authentication Issues
- [ ] Re-authenticate: `aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 517569678285.dkr.ecr.us-east-1.amazonaws.com`
- [ ] Verify AWS credentials: `aws sts get-caller-identity`

## Maintenance Tasks

### Regular Monitoring
- [ ] Monitor application logs daily
- [ ] Check disk space weekly
- [ ] Review system performance monthly
- [ ] Update Docker image when new versions available

### Backup Procedures
- [ ] Database backup: `sudo cp /opt/annotation-app/instance/annotation.db /backups/`
- [ ] Application data backup: `sudo tar -czf /backups/annotation-app-$(date +%Y%m%d).tar.gz /opt/annotation-app`
- [ ] Test backup restoration procedures

### Update Procedures
- [ ] Pull new image: `sudo ./update-deployment.sh v1.1.0`
- [ ] Validate update: `./validate-deployment.sh`
- [ ] Rollback if issues: Restore from backup

## Security Considerations

### Access Control
- [ ] Use strong SSH keys
- [ ] Limit SSH access to necessary IPs
- [ ] Regularly rotate access credentials
- [ ] Monitor access logs

### Application Security
- [ ] Use HTTPS in production (reverse proxy)
- [ ] Regular security updates
- [ ] Monitor for vulnerabilities
- [ ] Implement proper backup encryption

### Data Protection
- [ ] Encrypt sensitive data at rest
- [ ] Regular data backups
- [ ] Secure data transmission
- [ ] Access logging and monitoring

## Scaling Considerations

### Performance Optimization
- [ ] Monitor resource usage
- [ ] Optimize database queries
- [ ] Implement caching if needed
- [ ] Consider load balancing for high traffic

### Infrastructure Scaling
- [ ] Upgrade instance size if needed
- [ ] Implement auto-scaling groups
- [ ] Use RDS for database scaling
- [ ] Consider container orchestration (ECS/EKS)

## Support Information

### Key Commands
```bash
# Container management
sudo docker ps
sudo docker logs annotation-app
sudo docker restart annotation-app

# Service management
sudo systemctl status annotation-app
sudo systemctl restart annotation-app

# Application access
curl http://localhost:5000/health
curl http://localhost:5000

# Log analysis
sudo docker logs annotation-app --tail 100
sudo journalctl -u annotation-app -f
```

### Important Paths
- Application data: `/opt/annotation-app/`
- Container logs: `sudo docker logs annotation-app`
- System logs: `/var/log/syslog`
- Configuration: `/opt/annotation-app/docker-compose.yml`

### Contact Information
- AWS Support: AWS Console → Support Center
- Documentation: See `EC2_DEPLOYMENT_README.md`
- Troubleshooting: See validation script output

---

**Deployment Status**: ⏳ Ready for deployment
**Last Updated**: $(date)
**Version**: 1.0.0









