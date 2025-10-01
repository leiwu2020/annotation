#!/bin/bash

# Docker deployment script for Annotation System
# This script helps deploy the annotation system using Docker

set -e

echo "🚀 Annotation System Docker Deployment"
echo "======================================"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    echo "Visit: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo "❌ Docker daemon is not running. Please start Docker first."
    echo "On macOS: Start Docker Desktop"
    echo "On Linux: sudo systemctl start docker"
    exit 1
fi

echo "✅ Docker is installed and running"

# Check if Docker Compose is available
if command -v docker-compose &> /dev/null; then
    echo "✅ Docker Compose is available"
    USE_COMPOSE=true
else
    echo "⚠️  Docker Compose not found, using Docker directly"
    USE_COMPOSE=false
fi

# Build the Docker image
echo ""
echo "🔨 Building Docker image..."
docker build -t annotation-system .

if [ $? -eq 0 ]; then
    echo "✅ Docker image built successfully"
else
    echo "❌ Failed to build Docker image"
    exit 1
fi

# Deploy using Docker Compose if available
if [ "$USE_COMPOSE" = true ]; then
    echo ""
    echo "🐳 Deploying with Docker Compose..."
    docker-compose down 2>/dev/null || true  # Stop any existing containers
    docker-compose up -d
    
    if [ $? -eq 0 ]; then
        echo "✅ Application deployed successfully with Docker Compose"
        echo ""
        echo "📱 Access the application at: http://localhost:5000"
        echo "👤 Default admin credentials:"
        echo "   Username: admin"
        echo "   Password: admin123"
        echo ""
        echo "📊 To view logs: docker-compose logs -f"
        echo "🛑 To stop: docker-compose down"
    else
        echo "❌ Failed to deploy with Docker Compose"
        exit 1
    fi
else
    # Deploy using Docker directly
    echo ""
    echo "🐳 Deploying with Docker..."
    
    # Stop any existing container
    docker stop annotation-app 2>/dev/null || true
    docker rm annotation-app 2>/dev/null || true
    
    # Create named volumes if they don't exist
    docker volume create annotation_data 2>/dev/null || true
    docker volume create annotation_uploads 2>/dev/null || true
    
    # Run the container
    docker run -d \
        --name annotation-app \
        -p 5000:5000 \
        -v annotation_data:/app/instance \
        -v annotation_uploads:/app/uploads \
        annotation-system
    
    if [ $? -eq 0 ]; then
        echo "✅ Application deployed successfully with Docker"
        echo ""
        echo "📱 Access the application at: http://localhost:5000"
        echo "👤 Default admin credentials:"
        echo "   Username: admin"
        echo "   Password: admin123"
        echo ""
        echo "📊 To view logs: docker logs annotation-app"
        echo "🛑 To stop: docker stop annotation-app"
        echo "🗑️  To remove: docker rm annotation-app"
    else
        echo "❌ Failed to deploy with Docker"
        exit 1
    fi
fi

echo ""
echo "🎉 Deployment complete!"
echo ""
echo "📋 Useful commands:"
echo "   View logs: docker logs -f annotation-app"
echo "   Access container: docker exec -it annotation-app /bin/bash"
echo "   Check status: docker ps"
echo "   View volumes: docker volume ls"
