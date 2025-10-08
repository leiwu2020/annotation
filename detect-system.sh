#!/bin/bash

# Detect system init system and provide deployment guidance

echo "=========================================="
echo "  System Detection for Deployment"
echo "=========================================="
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Operating System: $PRETTY_NAME"
else
    echo "Operating System: $(uname -s) $(uname -r)"
fi

echo "Architecture: $(uname -m)"
echo ""

# Detect init system
echo "Init System Detection:"
if command -v systemctl &> /dev/null; then
    echo "✅ systemd detected"
    INIT_SYSTEM="systemd"
elif command -v service &> /dev/null && command -v update-rc.d &> /dev/null; then
    echo "✅ SysV init detected"
    INIT_SYSTEM="sysv"
elif command -v rc-service &> /dev/null; then
    echo "✅ OpenRC detected"
    INIT_SYSTEM="openrc"
else
    echo "⚠️  Unknown or minimal init system"
    INIT_SYSTEM="unknown"
fi

echo ""

# Check Docker
echo "Docker Status:"
if command -v docker &> /dev/null; then
    echo "✅ Docker installed"
    if docker info &> /dev/null; then
        echo "✅ Docker daemon running"
    else
        echo "❌ Docker daemon not running"
        echo ""
        echo "To start Docker:"
        case $INIT_SYSTEM in
            systemd)
                echo "  sudo systemctl start docker"
                echo "  sudo systemctl enable docker"
                ;;
            sysv)
                echo "  sudo service docker start"
                ;;
            openrc)
                echo "  sudo rc-service docker start"
                ;;
            *)
                echo "  sudo dockerd &"
                ;;
        esac
    fi
else
    echo "❌ Docker not installed"
    echo ""
    echo "Install Docker:"
    echo "  curl -fsSL https://get.docker.com -o get-docker.sh"
    echo "  sudo sh get-docker.sh"
fi

echo ""

# Check sudo
echo "Sudo Configuration:"
if [[ $EUID -eq 0 ]]; then
    echo "✅ Running as root"
elif sudo -n true 2>/dev/null; then
    echo "✅ Passwordless sudo configured"
else
    echo "❌ Sudo requires password"
    echo ""
    echo "To configure passwordless sudo:"
    echo "  echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers"
fi

echo ""

# Check AWS CLI
echo "AWS CLI Status:"
if command -v aws &> /dev/null; then
    echo "✅ AWS CLI installed"
    if aws sts get-caller-identity &> /dev/null; then
        echo "✅ AWS credentials configured"
    else
        echo "❌ AWS credentials not configured"
        echo "  Run: aws configure"
    fi
else
    echo "❌ AWS CLI not installed"
fi

echo ""

# Recommendations
echo "Deployment Recommendations:"
echo "=========================================="

if [ "$INIT_SYSTEM" = "systemd" ]; then
    echo "✅ Your system uses systemd - the standard deployment script will work perfectly"
    echo "   Run: ./deploy-to-ec2.sh"
elif [ "$INIT_SYSTEM" = "sysv" ]; then
    echo "✅ Your system uses SysV init - the deployment script will work with init.d scripts"
    echo "   Run: ./deploy-to-ec2.sh"
elif [ "$INIT_SYSTEM" = "openrc" ]; then
    echo "✅ Your system uses OpenRC - the deployment script will work with OpenRC services"
    echo "   Run: ./deploy-to-ec2.sh"
else
    echo "⚠️  Your system has a minimal or unknown init system"
    echo "   The deployment script will still work but won't configure auto-start"
    echo "   Run: ./deploy-to-ec2.sh"
    echo "   Manual start: cd /opt/annotation-app && docker-compose up -d"
fi

echo ""
echo "Alternative: Use the interactive version if you have issues:"
echo "   ./deploy-to-ec2-interactive.sh"


