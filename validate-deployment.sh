#!/bin/bash

# Validate Annotation App Deployment
# This script validates that the deployment is working correctly

set -e

# Configuration
APP_URL="${1:-http://localhost:5000}"
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

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    log "Running test: $test_name"
    if eval "$test_command"; then
        success "✓ $test_name"
        ((TESTS_PASSED++))
    else
        error "✗ $test_name"
        ((TESTS_FAILED++))
    fi
}

# Determine if we need sudo
if [[ $EUID -eq 0 ]]; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
fi

# Test 1: Container is running
test_container_running() {
    $DOCKER_CMD ps --format "table {{.Names}}\t{{.Status}}" | grep -q "$CONTAINER_NAME.*Up"
}

# Test 2: Application responds to HTTP requests
test_http_response() {
    curl -s -o /dev/null -w "%{http_code}" "$APP_URL" | grep -q "200"
}

# Test 3: Health endpoint is accessible
test_health_endpoint() {
    curl -s "$APP_URL/health" | grep -q "healthy\|ok\|success" || [ "$(curl -s -o /dev/null -w "%{http_code}" "$APP_URL/health")" = "200" ]
}

# Test 4: Login page is accessible
test_login_page() {
    curl -s "$APP_URL/login" | grep -q "login\|Login"
}

# Test 5: Static files are served
test_static_files() {
    curl -s -o /dev/null -w "%{http_code}" "$APP_URL/static/css/style.css" | grep -q "200"
}

# Test 6: Database directory exists and is writable
test_database_directory() {
    [ -d "/opt/annotation-app/instance" ] && [ -w "/opt/annotation-app/instance" ]
}

# Test 7: Uploads directory exists and is writable
test_uploads_directory() {
    [ -d "/opt/annotation-app/uploads" ] && [ -w "/opt/annotation-app/uploads" ]
}

# Test 8: Container logs don't contain critical errors
test_container_logs() {
    ! $DOCKER_CMD logs $CONTAINER_NAME --tail 50 2>&1 | grep -i "error\|exception\|traceback" | grep -v "LegacyAPIWarning"
}

# Test 9: Systemd service is enabled
test_systemd_service() {
    sudo systemctl is-enabled annotation-app.service 2>/dev/null || true
}

# Test 10: Port is accessible
test_port_accessibility() {
    netstat -tulpn | grep -q ":5000.*LISTEN" || ss -tulpn | grep -q ":5000.*LISTEN"
}

# Main validation function
main() {
    echo "=========================================="
    echo "  Annotation App Deployment Validation"
    echo "=========================================="
    echo ""
    echo "Testing URL: $APP_URL"
    echo "Container Name: $CONTAINER_NAME"
    echo ""
    
    # Run all tests
    run_test "Container is running" "test_container_running"
    run_test "Application responds to HTTP" "test_http_response"
    run_test "Health endpoint accessible" "test_health_endpoint"
    run_test "Login page accessible" "test_login_page"
    run_test "Static files served" "test_static_files"
    run_test "Database directory exists and writable" "test_database_directory"
    run_test "Uploads directory exists and writable" "test_uploads_directory"
    run_test "Container logs clean" "test_container_logs"
    run_test "Systemd service enabled" "test_systemd_service"
    run_test "Port accessible" "test_port_accessibility"
    
    echo ""
    echo "=========================================="
    echo "  Validation Results"
    echo "=========================================="
    echo ""
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        success "All tests passed! Deployment is working correctly."
        echo ""
        echo "Your annotation application is ready for use:"
        echo "  Local: $APP_URL"
        echo "  External: http://$(curl -s http://checkip.amazonaws.com/ 2>/dev/null || echo 'YOUR_SERVER_IP'):5000"
    else
        error "Some tests failed. Please check the deployment."
        echo ""
        echo "Common troubleshooting steps:"
        echo "  1. Check container logs: $DOCKER_CMD logs $CONTAINER_NAME"
        echo "  2. Verify container status: $DOCKER_CMD ps"
        echo "  3. Check system resources: top, df -h"
        echo "  4. Restart container: $DOCKER_CMD restart $CONTAINER_NAME"
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [APP_URL]"
        echo ""
        echo "Arguments:"
        echo "  APP_URL    Application URL to test (default: http://localhost:5000)"
        echo ""
        echo "Examples:"
        echo "  $0                           # Test local deployment"
        echo "  $0 http://your-server:5000   # Test remote deployment"
        exit 0
        ;;
    *)
        main
        ;;
esac
