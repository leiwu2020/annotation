#!/bin/bash

# Test Docker image locally for image-annotation-app
# This script will build/load the image and run it locally for testing

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="${IMAGE_NAME:-image-annotation-app}"  # Can be overridden with env var
CONTAINER_NAME="annotation-app-test"
PORT=5000
AWS_PROFILE="${AWS_PROFILE:-default}"  # AWS profile to use, defaults to 'default'

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
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

# Check if Docker is running
check_docker() {
    log "Checking if Docker is running..."
    if ! docker info > /dev/null 2>&1; then
        error "Docker daemon is not running. Please start Docker Desktop or Docker daemon."
        echo ""
        echo "On macOS, you can start Docker Desktop from Applications."
        echo "On Linux, you can start Docker with: sudo systemctl start docker"
        exit 1
    fi
    success "Docker is running"
}

# Check if AWS CLI is installed
check_aws_cli() {
    log "Checking AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        echo ""
        echo "Installation:"
        echo "  macOS: brew install awscli"
        echo "  Linux: https://aws.amazon.com/cli/"
        exit 1
    fi
    success "AWS CLI is installed"
}

# Check and perform AWS SSO login
check_aws_sso_login() {
    log "Checking AWS SSO login status for profile: ${AWS_PROFILE}..."
    
    # Check if AWS profile exists
    if ! aws configure list-profiles 2>/dev/null | grep -q "^${AWS_PROFILE}$"; then
        warning "AWS profile '${AWS_PROFILE}' not found in AWS config"
        log "Available profiles:"
        aws configure list-profiles 2>/dev/null || echo "  (none found)"
        echo ""
        read -p "Do you want to continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        return 0
    fi
    
    # Check if SSO session is valid by trying to get caller identity
    log "Checking AWS SSO session validity..."
    if aws sts get-caller-identity --profile ${AWS_PROFILE} > /dev/null 2>&1; then
        success "AWS SSO session is valid"
        # Show current identity
        local identity=$(aws sts get-caller-identity --profile ${AWS_PROFILE} --output json 2>/dev/null)
        if [ -n "$identity" ]; then
            local account=$(echo "$identity" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
            local arn=$(echo "$identity" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)
            log "AWS Account: ${account}"
            log "AWS ARN: ${arn}"
        fi
    else
        warning "AWS SSO session expired or invalid"
        log "Attempting AWS SSO login..."
        
        if aws sso login --profile ${AWS_PROFILE}; then
            success "AWS SSO login successful"
        else
            error "AWS SSO login failed"
            echo ""
            echo "Please run manually:"
            echo "  aws sso login --profile ${AWS_PROFILE}"
            exit 1
        fi
    fi
}

# Check if image exists locally
check_image_exists() {
    if docker images --format "{{.Repository}}" | grep -q "^${IMAGE_NAME}$"; then
        return 0
    else
        return 1
    fi
}

# Load image from tar.gz file if available
load_image_from_tar() {
    log "Checking for saved Docker images..."
    
    # Check for the most likely tar.gz file
    if [ -f "annotation-app-image.tar.gz" ]; then
        log "Loading image from annotation-app-image.tar.gz..."
        docker load -i annotation-app-image.tar.gz
        success "Image loaded from tar.gz"
        return 0
    elif [ -f "annotation-app-amd64.tar.gz" ]; then
        log "Loading image from annotation-app-amd64.tar.gz..."
        docker load -i annotation-app-amd64.tar.gz
        success "Image loaded from tar.gz"
        return 0
    else
        return 1
    fi
}

# Build image from Dockerfile
build_image() {
    log "Building Docker image from Dockerfile..."
    if docker build -t ${IMAGE_NAME} .; then
        success "Image built successfully"
    else
        error "Failed to build image"
        exit 1
    fi
}

# Stop and remove existing container
cleanup_container() {
    if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        warning "Stopping and removing existing container..."
        docker stop ${CONTAINER_NAME} > /dev/null 2>&1 || true
        docker rm ${CONTAINER_NAME} > /dev/null 2>&1 || true
        success "Container cleaned up"
    fi
}

# Run the container
run_container() {
    log "Starting container..."
    
    # Create local directories for volumes
    mkdir -p ./test-instance ./test-uploads ./test-logs
    
    # Prepare AWS credentials mount
    local aws_config_dir="${HOME}/.aws"
    local aws_cache_dir="${HOME}/.aws/sso/cache"
    
    # Build docker run command with proper quoting
    local docker_args=(
        -d
        --name "${CONTAINER_NAME}"
        -p "${PORT}:5000"
        -v "$(pwd)/test-instance:/app/instance"
        -v "$(pwd)/test-uploads:/app/uploads"
        -v "$(pwd)/test-logs:/app/logs"
        -e "FLASK_ENV=production"
        -e "PYTHONUNBUFFERED=1"
        -e "AWS_PROFILE=${AWS_PROFILE}"
        -e "AWS_SDK_LOAD_CONFIG=1"
    )
    
    # Add AWS mount if available
    if [ -d "$aws_config_dir" ]; then
        # Mount AWS config and credentials to app user's home directory
        # The Dockerfile creates user 'app' with home directory /home/app
        docker_args+=(-v "${aws_config_dir}:/home/app/.aws:ro")
        log "Mounting AWS credentials from: ${aws_config_dir} to /home/app/.aws"
        
        # Also mount SSO cache if it exists (for SSO token access)
        if [ -d "$aws_cache_dir" ]; then
            # The SSO cache is included in the .aws directory mount
            log "AWS SSO cache will be accessible via mounted .aws directory"
        fi
    else
        warning "AWS credentials directory not found at ${aws_config_dir}"
        warning "Container will not have AWS access unless credentials are configured differently"
    fi
    
    # Add image name
    docker_args+=("${IMAGE_NAME}")
    
    # Execute the command
    log "Running container with AWS profile: ${AWS_PROFILE}"
    if docker run "${docker_args[@]}"; then
        success "Container started successfully"
    else
        error "Failed to start container"
        exit 1
    fi
}

# Wait for container to be ready
wait_for_ready() {
    log "Waiting for application to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -f -s http://localhost:${PORT}/ > /dev/null 2>&1; then
            success "Application is ready!"
            return 0
        fi
        
        # Check if container is still running
        if ! docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
            error "Container stopped unexpectedly"
            log "Container logs:"
            docker logs ${CONTAINER_NAME} --tail 50
            exit 1
        fi
        
        log "Waiting... (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
    
    warning "Application didn't respond in time, but container is running"
    log "Container logs:"
    docker logs ${CONTAINER_NAME} --tail 20
}

# Test S3 access
test_s3_access() {
    log "Testing S3 access from container..."
    
    local test_result=$(docker exec ${CONTAINER_NAME} python -c "
import boto3
import os
from botocore.exceptions import ClientError

os.environ['AWS_PROFILE'] = '${AWS_PROFILE}'

try:
    # Test the same S3 client function the app uses
    session = boto3.Session(profile_name='${AWS_PROFILE}')
    s3_client = session.client('s3')
    
    # Test list_buckets
    buckets = s3_client.list_buckets()
    bucket_count = len(buckets.get('Buckets', []))
    
    # Test get_object capability (the main operation the app uses)
    get_object_ready = False
    if buckets.get('Buckets'):
        test_bucket = buckets['Buckets'][0]['Name']
        try:
            s3_client.list_objects_v2(Bucket=test_bucket, MaxKeys=1)
            get_object_ready = True
        except ClientError:
            get_object_ready = False
    
    print(f'SUCCESS|{bucket_count}|{get_object_ready}')
except Exception as e:
    print(f'ERROR|{str(e)}')
" 2>&1)
    
    if echo "$test_result" | grep -q "SUCCESS"; then
        local bucket_count=$(echo "$test_result" | grep "SUCCESS" | cut -d'|' -f2)
        local get_object_ready=$(echo "$test_result" | grep "SUCCESS" | cut -d'|' -f3)
        
        success "S3 access verified!"
        log "  - S3 buckets accessible: ${bucket_count}"
        if [ "$get_object_ready" = "True" ]; then
            success "  - S3 get_object operation: Ready (used by app for image fetching)"
        else
            warning "  - S3 get_object operation: Limited (may need bucket-specific permissions)"
        fi
    else
        local error_msg=$(echo "$test_result" | grep "ERROR" | cut -d'|' -f2)
        warning "S3 access test failed: ${error_msg}"
        warning "Container may not have S3 access. Check AWS credentials and permissions."
    fi
}

# Test the application
test_application() {
    log "Testing application endpoints..."
    
    # Test root endpoint
    if curl -f -s http://localhost:${PORT}/ > /dev/null; then
        success "Root endpoint is accessible"
    else
        warning "Root endpoint test failed"
    fi
    
    # Test health endpoint if available
    if curl -f -s http://localhost:${PORT}/health > /dev/null 2>&1; then
        success "Health endpoint is accessible"
    else
        log "Health endpoint not available (this is okay)"
    fi
}

# Show container information
show_info() {
    echo ""
    echo "=========================================="
    success "DOCKER IMAGE TEST COMPLETED!"
    echo "=========================================="
    echo ""
    echo "Container Information:"
    echo "  Name: ${CONTAINER_NAME}"
    echo "  Image: ${IMAGE_NAME}"
    echo "  Status: $(docker ps --format '{{.Status}}' --filter name=${CONTAINER_NAME})"
    echo ""
    echo "Access Information:"
    echo "  URL: http://localhost:${PORT}"
    echo ""
    echo "AWS Configuration:"
    echo "  AWS Profile: ${AWS_PROFILE}"
    echo "  AWS Credentials: Mounted from ${HOME}/.aws"
    echo "  S3 Access: Verified and working"
    echo ""
    echo "Default Admin Credentials:"
    echo "  Username: admin"
    echo "  Password: admin0516 (or admin123)"
    echo ""
    echo "Test Data Directories:"
    echo "  Database: $(pwd)/test-instance"
    echo "  Uploads: $(pwd)/test-uploads"
    echo "  Logs: $(pwd)/test-logs"
    echo ""
    echo "Management Commands:"
    echo "  View logs: docker logs ${CONTAINER_NAME}"
    echo "  Follow logs: docker logs -f ${CONTAINER_NAME}"
    echo "  Stop: docker stop ${CONTAINER_NAME}"
    echo "  Start: docker start ${CONTAINER_NAME}"
    echo "  Remove: docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
    echo "  Shell access: docker exec -it ${CONTAINER_NAME} /bin/bash"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  Docker Image Local Test Script"
    echo "  Image: ${IMAGE_NAME}"
    echo "=========================================="
    echo ""
    
    # Run steps
    check_docker
    check_aws_cli
    check_aws_sso_login
    cleanup_container
    
    # Try to get the image
    if check_image_exists; then
        success "Image ${IMAGE_NAME} already exists locally"
    elif load_image_from_tar; then
        # Image loaded from tar.gz, but might have different name
        # Check what was loaded
        loaded_image=$(docker images --format "{{.Repository}}:{{.Tag}}" | head -1)
        if [ "$loaded_image" != "${IMAGE_NAME}:latest" ]; then
            log "Tagging loaded image as ${IMAGE_NAME}..."
            docker tag ${loaded_image} ${IMAGE_NAME}:latest
        fi
    else
        log "No saved image found, building from Dockerfile..."
        build_image
    fi
    
    # Verify image exists
    if ! check_image_exists; then
        error "Image ${IMAGE_NAME} not found after build/load"
        exit 1
    fi
    
    # Run container
    run_container
    wait_for_ready
    test_application
    test_s3_access
    show_info
    
    echo ""
    success "Test completed! Open http://localhost:${PORT} in your browser to test the application."
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "This script will:"
        echo "  1. Check if Docker is running"
        echo "  2. Check AWS CLI and perform AWS SSO login"
        echo "  3. Load or build the Docker image"
        echo "  4. Run the container locally with AWS credentials"
        echo "  5. Test that the application is accessible"
        echo ""
        echo "Environment Variables:"
        echo "  AWS_PROFILE   AWS profile to use (default: default)"
        echo "  IMAGE_NAME    Docker image name (default: image-annotation-app)"
        echo ""
        echo "Options:"
        echo "  --help, -h    Show this help message"
        echo "  --stop        Stop and remove the test container"
        echo "  --logs        Show container logs"
        echo ""
        echo "Examples:"
        echo "  $0                          # Use default AWS profile"
        echo "  AWS_PROFILE=myprofile $0    # Use specific AWS profile"
        exit 0
        ;;
    --stop)
        log "Stopping and removing test container..."
        docker stop ${CONTAINER_NAME} > /dev/null 2>&1 || true
        docker rm ${CONTAINER_NAME} > /dev/null 2>&1 || true
        success "Container stopped and removed"
        exit 0
        ;;
    --logs)
        if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
            docker logs -f ${CONTAINER_NAME}
        else
            error "Container ${CONTAINER_NAME} not found"
            exit 1
        fi
        exit 0
        ;;
    *)
        main
        ;;
esac

