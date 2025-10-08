#!/bin/bash

# Update Annotation App Deployment on EC2
# This script updates an existing deployment with a new image

set -e

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="annotation-app"
CONTAINER_NAME="annotation-app"

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

# Get new image tag
NEW_TAG="${1:-latest}"

if [ "$NEW_TAG" = "--help" ] || [ "$NEW_TAG" = "-h" ]; then
    echo "Usage: $0 [NEW_IMAGE_TAG]"
    echo ""
    echo "Arguments:"
    echo "  NEW_IMAGE_TAG    New Docker image tag to deploy (default: latest)"
    echo ""
    echo "Examples:"
    echo "  $0           # Update to latest image"
    echo "  $0 v1.1.0   # Update to v1.1.0 image"
    exit 0
fi

log "Starting update to image tag: $NEW_TAG"

# Determine if we need sudo
if [[ $EUID -eq 0 ]]; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
fi

# Check if container exists
if ! $DOCKER_CMD ps -a --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    error "Container $CONTAINER_NAME not found. Please run the initial deployment script first."
    exit 1
fi

# Authenticate with ECR
log "Authenticating with ECR..."
aws ecr get-login-password --region us-east-1 | $DOCKER_CMD login --username AWS --password-stdin $ECR_REGISTRY

# Pull new image
log "Pulling new image: $ECR_REGISTRY/$ECR_REPOSITORY:$NEW_TAG"
$DOCKER_CMD pull $ECR_REGISTRY/$ECR_REPOSITORY:$NEW_TAG

# Update docker-compose.yml with new image
log "Updating docker-compose.yml with new image..."
cd /opt/annotation-app

# Backup current compose file
cp docker-compose.yml docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)

# Update the image tag in docker-compose.yml
sed -i "s|image: $ECR_REGISTRY/$ECR_REPOSITORY:.*|image: $ECR_REGISTRY/$ECR_REPOSITORY:$NEW_TAG|" docker-compose.yml

# Stop current container
log "Stopping current container..."
$DOCKER_CMD-compose down

# Start with new image
log "Starting container with new image..."
$DOCKER_CMD-compose up -d

# Wait for health check
log "Waiting for container to be healthy..."
sleep 10

if $DOCKER_CMD ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$CONTAINER_NAME.*Up"; then
    success "Update completed successfully!"
    echo ""
    echo "Container Status:"
    $DOCKER_CMD ps --filter name=$CONTAINER_NAME --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "Recent logs:"
    $DOCKER_CMD logs $CONTAINER_NAME --tail 10
else
    error "Update failed. Rolling back..."
    $DOCKER_CMD-compose -f docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S) up -d
    exit 1
fi
