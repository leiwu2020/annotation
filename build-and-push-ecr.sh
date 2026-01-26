#!/bin/bash
# Script to build Docker image and push to AWS ECR

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
REPOSITORY="image-annotation-app"
LOCAL_IMAGE_NAME="image-annotation-app"
IMAGE_TAG="${1:-latest}"  # Use first argument as tag, default to 'latest'
REGION="us-east-1"
AWS_PROFILE="${AWS_PROFILE:-default}"

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
        exit 1
    fi
    success "Docker is running"
}

# Check if AWS CLI is installed
check_aws_cli() {
    log "Checking AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    success "AWS CLI is installed"
}

# Check AWS SSO login
check_aws_sso() {
    log "Checking AWS SSO login status for profile: ${AWS_PROFILE}..."
    
    if ! aws configure list-profiles 2>/dev/null | grep -q "^${AWS_PROFILE}$"; then
        warning "AWS profile '${AWS_PROFILE}' not found"
        log "Available profiles:"
        aws configure list-profiles 2>/dev/null || echo "  (none found)"
    fi
    
    log "Checking AWS SSO session validity..."
    if aws sts get-caller-identity --profile ${AWS_PROFILE} > /dev/null 2>&1; then
        success "AWS SSO session is valid"
        local identity=$(aws sts get-caller-identity --profile ${AWS_PROFILE} --output json 2>/dev/null)
        local account=$(echo "$identity" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
        log "AWS Account: ${account}"
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

# Ensure ECR repository exists
ensure_ecr_repository() {
    log "Checking if ECR repository exists..."
    
    if aws ecr describe-repositories --repository-names ${REPOSITORY} --region ${REGION} --profile ${AWS_PROFILE} > /dev/null 2>&1; then
        success "ECR repository '${REPOSITORY}' exists"
    else
        warning "ECR repository '${REPOSITORY}' does not exist. Creating it..."
        
        if aws ecr create-repository \
            --repository-name ${REPOSITORY} \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256 > /dev/null 2>&1; then
            success "ECR repository '${REPOSITORY}' created"
        else
            error "Failed to create ECR repository"
            exit 1
        fi
    fi
}

# Authenticate with ECR
authenticate_ecr() {
    log "Authenticating with ECR..."
    if aws ecr get-login-password --region ${REGION} --profile ${AWS_PROFILE} | docker login --username AWS --password-stdin ${ECR_REGISTRY}; then
        success "Successfully authenticated with ECR"
    else
        error "Failed to authenticate with ECR. Please check your AWS credentials."
        exit 1
    fi
}

# Build the Docker image
build_image() {
    log "Building Docker image: ${LOCAL_IMAGE_NAME}:${IMAGE_TAG}..."
    log "This may take several minutes..."
    
    if docker build -t ${LOCAL_IMAGE_NAME}:${IMAGE_TAG} .; then
        success "Image built successfully: ${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"
    else
        error "Failed to build image"
        exit 1
    fi
}

# Tag the image for ECR
tag_image() {
    local ecr_image="${ECR_REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"
    log "Tagging image for ECR: ${ecr_image}"
    
    docker tag ${LOCAL_IMAGE_NAME}:${IMAGE_TAG} ${ecr_image}
    success "Image tagged as ${ecr_image}"
}

# Push the image to ECR
push_image() {
    local ecr_image="${ECR_REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"
    log "Pushing image to ECR..."
    log "Image: ${ecr_image}"
    log "This may take several minutes depending on image size..."
    
    if docker push ${ecr_image}; then
        success "Image pushed successfully to ECR"
    else
        error "Failed to push image to ECR"
        exit 1
    fi
}

# Show summary
show_summary() {
    local ecr_image="${ECR_REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"
    
    echo ""
    echo "=========================================="
    success "BUILD AND PUSH COMPLETED!"
    echo "=========================================="
    echo ""
    echo "Image Information:"
    echo "  Local Image: ${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"
    echo "  ECR Image: ${ecr_image}"
    echo "  Repository: ${REPOSITORY}"
    echo "  Tag: ${IMAGE_TAG}"
    echo "  Region: ${REGION}"
    echo ""
    echo "Next Steps:"
    echo "  Deploy to EC2:"
    echo "    ./deploy-to-ec2-interactive.sh ${IMAGE_TAG} 5000 5000"
    echo ""
    echo "  Pull image manually:"
    echo "    docker pull ${ecr_image}"
    echo ""
    echo "  View in AWS Console:"
    echo "    https://console.aws.amazon.com/ecr/repositories/private/${ECR_REGISTRY#*.}/${REPOSITORY}?region=${REGION}"
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "  Build and Push to AWS ECR"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Local Image: ${LOCAL_IMAGE_NAME}:${IMAGE_TAG}"
    echo "  ECR Registry: ${ECR_REGISTRY}"
    echo "  Repository: ${REPOSITORY}"
    echo "  Tag: ${IMAGE_TAG}"
    echo "  Region: ${REGION}"
    echo "  AWS Profile: ${AWS_PROFILE}"
    echo ""
    
    # Run steps
    check_docker
    check_aws_cli
    check_aws_sso
    ensure_ecr_repository
    authenticate_ecr
    build_image
    tag_image
    push_image
    show_summary
    
    echo ""
    success "All steps completed successfully!"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [IMAGE_TAG]"
        echo ""
        echo "Builds the Docker image and pushes it to AWS ECR."
        echo ""
        echo "Arguments:"
        echo "  IMAGE_TAG    Docker image tag (default: latest)"
        echo ""
        echo "Environment Variables:"
        echo "  AWS_PROFILE  AWS profile to use (default: default)"
        echo ""
        echo "Examples:"
        echo "  $0                    # Build and push with tag 'latest'"
        echo "  $0 v1.0.0            # Build and push with tag 'v1.0.0'"
        echo "  AWS_PROFILE=myprofile $0  # Use specific AWS profile"
        exit 0
        ;;
    *)
        main
        ;;
esac

