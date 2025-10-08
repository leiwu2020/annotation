#!/bin/bash

# Quick setup for passwordless sudo
# Run this script to configure passwordless sudo for deployment

echo "=========================================="
echo "  Quick Sudo Setup for Deployment"
echo "=========================================="
echo ""

# Get current user
CURRENT_USER=$(whoami)
echo "Current user: $CURRENT_USER"
echo ""

# Check if already configured
if sudo -n true 2>/dev/null; then
    echo "✅ Passwordless sudo is already configured!"
    echo ""
    echo "You can now run the deployment script:"
    echo "  ./deploy-to-ec2.sh"
    exit 0
fi

echo "This will add passwordless sudo for $CURRENT_USER"
echo ""

# Add passwordless sudo rule
echo "Adding passwordless sudo rule..."
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers

# Test the configuration
echo ""
echo "Testing passwordless sudo..."
if sudo -n true 2>/dev/null; then
    echo "✅ Passwordless sudo configured successfully!"
    echo ""
    echo "You can now run the deployment script:"
    echo "  ./deploy-to-ec2.sh"
else
    echo "❌ Failed to configure passwordless sudo"
    echo ""
    echo "You can still run the deployment script with sudo:"
    echo "  sudo ./deploy-to-ec2.sh"
fi

echo ""
echo "To remove passwordless sudo later:"
echo "  sudo visudo"
echo "  # Remove the line: $CURRENT_USER ALL=(ALL) NOPASSWD: ALL"


