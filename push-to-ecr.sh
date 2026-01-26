#!/bin/bash
# Script to push Docker image to AWS ECR

set -e

ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
REPOSITORY="annotation-app"
IMAGE_TAG="latest"
REGION="us-east-1"

echo "=========================================="
echo "  Pushing Annotation App to AWS ECR"
echo "=========================================="
echo ""

# Check if image exists
if ! docker images | grep -q "annotation-app.*latest"; then
    echo "Error: annotation-app:latest image not found"
    echo "Please build the image first: docker build -t annotation-app:latest ."
    exit 1
fi

# Authenticate with ECR
echo "Step 1: Authenticating with ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

if [ $? -ne 0 ]; then
    echo "Error: Failed to authenticate with ECR"
    echo "Please ensure AWS SSO is authenticated: aws sso login"
    exit 1
fi

echo "✓ Successfully authenticated with ECR"
echo ""

# Tag the image
echo "Step 2: Tagging image for ECR..."
docker tag annotation-app:latest $ECR_REGISTRY/$REPOSITORY:$IMAGE_TAG
echo "✓ Image tagged as $ECR_REGISTRY/$REPOSITORY:$IMAGE_TAG"
echo ""

# Push the image
echo "Step 3: Pushing image to ECR..."
echo "This may take several minutes depending on image size..."
docker push $ECR_REGISTRY/$REPOSITORY:$IMAGE_TAG

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ SUCCESS! Image pushed to ECR"
    echo "=========================================="
    echo ""
    echo "Image URI: $ECR_REGISTRY/$REPOSITORY:$IMAGE_TAG"
    echo ""
    echo "You can now deploy this image using:"
    echo "  ./deploy-to-ec2-interactive.sh latest 5000 5000"
    echo ""
else
    echo ""
    echo "Error: Failed to push image to ECR"
    exit 1
fi

