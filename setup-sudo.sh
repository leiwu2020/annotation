#!/bin/bash

# Setup passwordless sudo for deployment script
# This script helps configure passwordless sudo for the current user

set -e

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

# Get current user
CURRENT_USER=$(whoami)

echo "=========================================="
echo "  Passwordless Sudo Setup"
echo "=========================================="
echo ""
echo "This script will configure passwordless sudo for user: $CURRENT_USER"
echo "This is required for the deployment script to work properly."
echo ""

# Check if already has passwordless sudo
if sudo -n true 2>/dev/null; then
    success "Passwordless sudo is already configured for $CURRENT_USER"
    echo ""
    echo "You can now run the deployment script:"
    echo "  ./deploy-to-ec2.sh"
    exit 0
fi

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. Please run as a regular user."
    exit 1
fi

# Confirm with user
echo "This will add the following line to the sudoers file:"
echo "  $CURRENT_USER ALL=(ALL) NOPASSWD: ALL"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    echo ""
    echo "Alternative options:"
    echo "1. Run the deployment script with sudo: sudo ./deploy-to-ec2.sh"
    echo "2. Manually configure sudo: sudo visudo"
    exit 0
fi

# Backup current sudoers file
log "Creating backup of sudoers file..."
sudo cp /etc/sudoers /etc/sudoers.backup.$(date +%Y%m%d_%H%M%S)

# Add passwordless sudo rule
log "Adding passwordless sudo rule..."
echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers > /dev/null

# Test the configuration
log "Testing passwordless sudo..."
if sudo -n true 2>/dev/null; then
    success "Passwordless sudo configured successfully!"
    echo ""
    echo "You can now run the deployment script without sudo:"
    echo "  ./deploy-to-ec2.sh"
    echo ""
    echo "To revert this change later, run:"
    echo "  sudo visudo"
    echo "  # Remove the line: $CURRENT_USER ALL=(ALL) NOPASSWD: ALL"
else
    error "Failed to configure passwordless sudo. Please check the sudoers file."
    echo ""
    echo "To restore from backup:"
    echo "  sudo cp /etc/sudoers.backup.$(date +%Y%m%d_%H%M%S) /etc/sudoers"
    exit 1
fi

echo ""
success "Setup completed successfully!"









