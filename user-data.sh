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
