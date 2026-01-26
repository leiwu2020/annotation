#!/bin/bash

# Deploy image-annotation-app to EC2 t3.small instance in us-east-1
# This script updates the deployment script to use image-annotation-app repository

set -e  # Exit on any error

# Configuration
ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="image-annotation-app"  # Updated to use image-annotation-app
IMAGE_TAG="${1:-latest}"  # Use first argument as tag, default to 'latest'
CONTAINER_NAME="image-annotation-app"
APP_PORT="${2:-5000}"     # Use second argument as port, default to 5000
HOST_PORT="${3:-5000}"    # Use third argument as host port, default to 5000
INSTANCE_TYPE="t3.small"
REGION="us-east-1"
AWS_PROFILE="${AWS_PROFILE:-default}"
SSH_KEY="${SSH_KEY:-}"  # SSH key path (can be set via environment variable)
SSH_USER="${SSH_USER:-ec2-user}"  # SSH user (default: ec2-user for Amazon Linux)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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

# Check AWS CLI
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
    
    if ! aws sts get-caller-identity --profile ${AWS_PROFILE} > /dev/null 2>&1; then
        warning "AWS SSO session expired or invalid"
        log "Attempting AWS SSO login..."
        
        if aws sso login --profile ${AWS_PROFILE}; then
            success "AWS SSO login successful"
        else
            error "AWS SSO login failed"
            echo "Please run manually: aws sso login --profile ${AWS_PROFILE}"
            exit 1
        fi
    else
        success "AWS SSO session is valid"
    fi
}

# Check and attach IAM role to EC2 instance
check_and_attach_iam_role() {
    local ROLE_NAME="${1:-ec2-s3-access}"
    
    log "Checking IAM role attachment for instance: ${INSTANCE_ID}..."
    
    # Get current IAM role
    CURRENT_ROLE=$(aws ec2 describe-instances \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --instance-ids ${INSTANCE_ID} \
        --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
        --output text 2>/dev/null || echo "None")
    
    if [ -n "$CURRENT_ROLE" ] && [ "$CURRENT_ROLE" != "None" ] && [ "$CURRENT_ROLE" != "null" ]; then
        log "Instance already has IAM role attached: ${CURRENT_ROLE}"
        # Extract role name from ARN
        ROLE_NAME_FROM_ARN=$(echo "$CURRENT_ROLE" | sed 's/.*instance-profile\///')
        success "IAM role '${ROLE_NAME_FROM_ARN}' is attached to the instance"
        return 0
    fi
    
    # Check if the role exists
    log "Checking if IAM role '${ROLE_NAME}' exists..."
    if aws iam get-role --role-name ${ROLE_NAME} --profile ${AWS_PROFILE} >/dev/null 2>&1; then
        log "IAM role '${ROLE_NAME}' exists"
    else
        warning "IAM role '${ROLE_NAME}' does not exist"
        log "You need to create the IAM role first. Here's the command:"
        echo ""
        echo "aws iam create-role --role-name ${ROLE_NAME} \\"
        echo "  --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}' \\"
        echo "  --profile ${AWS_PROFILE}"
        echo ""
        echo "aws iam attach-role-policy --role-name ${ROLE_NAME} \\"
        echo "  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \\"
        echo "  --profile ${AWS_PROFILE}"
        echo ""
        echo "aws iam create-instance-profile --instance-profile-name ${ROLE_NAME} --profile ${AWS_PROFILE}"
        echo ""
        echo "aws iam add-role-to-instance-profile --instance-profile-name ${ROLE_NAME} --role-name ${ROLE_NAME} --profile ${AWS_PROFILE}"
        echo ""
        return 1
    fi
    
    # Check if instance profile exists
    INSTANCE_PROFILE_NAME="${ROLE_NAME}"
    if aws iam get-instance-profile --instance-profile-name ${INSTANCE_PROFILE_NAME} --profile ${AWS_PROFILE} >/dev/null 2>&1; then
        log "Instance profile '${INSTANCE_PROFILE_NAME}' exists"
    else
        warning "Instance profile '${INSTANCE_PROFILE_NAME}' does not exist"
        log "Creating instance profile..."
        aws iam create-instance-profile --instance-profile-name ${INSTANCE_PROFILE_NAME} --profile ${AWS_PROFILE} >/dev/null 2>&1 || {
            error "Failed to create instance profile"
            return 1
        }
        
        # Add role to instance profile
        log "Adding role to instance profile..."
        aws iam add-role-to-instance-profile \
            --instance-profile-name ${INSTANCE_PROFILE_NAME} \
            --role-name ${ROLE_NAME} \
            --profile ${AWS_PROFILE} >/dev/null 2>&1 || {
            error "Failed to add role to instance profile"
            return 1
        }
        
        # Wait a bit for the instance profile to be ready
        log "Waiting for instance profile to be ready..."
        sleep 3
    fi
    
    # Attach IAM role to instance
    log "Attaching IAM role '${ROLE_NAME}' to instance..."
    aws ec2 associate-iam-instance-profile \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --instance-id ${INSTANCE_ID} \
        --iam-instance-profile Name=${INSTANCE_PROFILE_NAME} >/dev/null 2>&1 || {
        error "Failed to attach IAM role to instance"
        log "You may need to detach any existing IAM role first, or the instance may already have a role attached"
        return 1
    }
    
    success "IAM role '${ROLE_NAME}' attached to instance successfully"
    log "Note: It may take a few seconds for the role to be available on the instance"
    return 0
}

# Get or create EC2 instance
get_or_create_instance() {
    log "Checking for existing EC2 instances..."
    
    # Look for running instances with tag Name=image-annotation-app
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --filters "Name=tag:Name,Values=image-annotation-app" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
        success "Found existing running instance: ${INSTANCE_ID}"
        INSTANCE_IP=$(aws ec2 describe-instances \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids ${INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        log "Instance IP: ${INSTANCE_IP}"
        return 0
    fi
    
    # Check for stopped instances
    STOPPED_INSTANCE_ID=$(aws ec2 describe-instances \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --filters "Name=tag:Name,Values=image-annotation-app" \
                  "Name=instance-state-name,Values=stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$STOPPED_INSTANCE_ID" != "None" ] && [ -n "$STOPPED_INSTANCE_ID" ]; then
        log "Found stopped instance: ${STOPPED_INSTANCE_ID}. Starting it..."
        aws ec2 start-instances \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids ${STOPPED_INSTANCE_ID} > /dev/null
        
        log "Waiting for instance to be running..."
        aws ec2 wait instance-running \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids ${STOPPED_INSTANCE_ID}
        
        INSTANCE_ID=${STOPPED_INSTANCE_ID}
        INSTANCE_IP=$(aws ec2 describe-instances \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids ${INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        success "Instance started: ${INSTANCE_ID}"
        log "Instance IP: ${INSTANCE_IP}"
        return 0
    fi
    
    # No existing instance, need to create one
    warning "No existing EC2 instance found. You need to create one first."
    echo ""
    echo "To create a t3.small instance in us-east-1, run:"
    echo ""
    echo "aws ec2 run-instances \\"
    echo "  --region ${REGION} \\"
    echo "  --profile ${AWS_PROFILE} \\"
    echo "  --image-id ami-0c55b159cbfafe1f0 \\"
    echo "  --instance-type ${INSTANCE_TYPE} \\"
    echo "  --key-name YOUR_KEY_NAME \\"
    echo "  --security-group-ids sg-XXXXXXXXX \\"
    echo "  --subnet-id subnet-XXXXXXXXX \\"
    echo "  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=image-annotation-app}]' \\"
    echo "  --user-data file://ec2-user-data.sh"
    echo ""
    echo "Or use the AWS Console to launch an instance with:"
    echo "  - Instance type: ${INSTANCE_TYPE}"
    echo "  - Region: ${REGION}"
    echo "  - Tag Name: image-annotation-app"
    echo ""
    echo "After creating the instance, run this script again."
    exit 1
}

# Share AWS profile with EC2 instance
share_aws_profile() {
    log "Sharing AWS profile '${AWS_PROFILE}' with EC2 instance..."
    
    # Get AWS config directory
    AWS_CONFIG_DIR="${HOME}/.aws"
    AWS_CONFIG_FILE="${AWS_CONFIG_DIR}/config"
    AWS_CREDENTIALS_FILE="${AWS_CONFIG_DIR}/credentials"
    
    # Check if AWS config exists
    if [ ! -d "${AWS_CONFIG_DIR}" ]; then
        error "AWS config directory not found at ${AWS_CONFIG_DIR}"
        return 1
    fi
    
    # Check if profile exists in config
    if [ -f "${AWS_CONFIG_FILE}" ]; then
        if ! grep -q "\[profile ${AWS_PROFILE}\]" "${AWS_CONFIG_FILE}" && ! grep -q "\[${AWS_PROFILE}\]" "${AWS_CONFIG_FILE}"; then
            warning "Profile '${AWS_PROFILE}' not found in AWS config"
            log "Available profiles:"
            grep -E "^\[(profile )?[^]]+\]" "${AWS_CONFIG_FILE}" 2>/dev/null || echo "  (none found)"
        fi
    fi
    
    # Try to copy via SSM first
    log "Attempting to copy AWS profile via SSM..."
    SSM_AVAILABLE=false
    if aws ssm describe-instance-information \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].InstanceId' \
        --output text 2>/dev/null | grep -q "${INSTANCE_ID}"; then
        SSM_AVAILABLE=true
    fi
    
    if [ "$SSM_AVAILABLE" = true ]; then
        # Create base64 encoded config and credentials
        if [ -f "${AWS_CONFIG_FILE}" ]; then
            CONFIG_B64=$(base64 -i "${AWS_CONFIG_FILE}" 2>/dev/null || base64 "${AWS_CONFIG_FILE}")
        else
            CONFIG_B64=""
        fi
        
        CREDENTIALS_B64=""
        if [ -f "${AWS_CREDENTIALS_FILE}" ]; then
            CREDENTIALS_B64=$(base64 -i "${AWS_CREDENTIALS_FILE}" 2>/dev/null || base64 "${AWS_CREDENTIALS_FILE}")
        fi
        
        # Build SSM commands array
        SSM_COMMANDS=(
            "mkdir -p ~/.aws && chmod 700 ~/.aws"
        )
        
        # Add config file setup
        if [ -n "$CONFIG_B64" ]; then
            SSM_COMMANDS+=("echo '${CONFIG_B64}' | base64 -d > ~/.aws/config && chmod 600 ~/.aws/config")
        fi
        
        # Add credentials file setup
        if [ -n "$CREDENTIALS_B64" ]; then
            SSM_COMMANDS+=("echo '${CREDENTIALS_B64}' | base64 -d > ~/.aws/credentials && chmod 600 ~/.aws/credentials")
        fi
        
        SSM_COMMANDS+=("echo 'AWS profile configured successfully'")
        
        # Convert commands array to JSON format for SSM
        COMMANDS_JSON="["
        for i in "${!SSM_COMMANDS[@]}"; do
            if [ $i -gt 0 ]; then
                COMMANDS_JSON+=","
            fi
            # Escape double quotes in the command
            ESCAPED_CMD=$(echo "${SSM_COMMANDS[$i]}" | sed 's/"/\\"/g')
            COMMANDS_JSON+="\"${ESCAPED_CMD}\""
        done
        COMMANDS_JSON+="]"
        
        # Send command via SSM
        COMMAND_ID=$(aws ssm send-command \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=${COMMANDS_JSON}" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)
        
        if [ -n "$COMMAND_ID" ] && [ "$COMMAND_ID" != "None" ]; then
            log "SSM command sent. Command ID: ${COMMAND_ID}"
            log "Waiting for command to complete..."
            sleep 5
            
            # Check command status
            COMMAND_STATUS=$(aws ssm get-command-invocation \
                --region ${REGION} \
                --profile ${AWS_PROFILE} \
                --command-id "${COMMAND_ID}" \
                --instance-id "${INSTANCE_ID}" \
                --query 'Status' \
                --output text 2>/dev/null || echo "Failed")
            
            if [ "$COMMAND_STATUS" = "Success" ]; then
                success "AWS profile copied to EC2 via SSM"
                
                # For SSO profiles, provide instructions
                if [ -d "${AWS_CONFIG_DIR}/sso/cache" ]; then
                    log "Note: SSO cache directory found. SSO sessions may need to be refreshed on EC2."
                    log "You may need to run 'aws sso login --profile ${AWS_PROFILE}' on the EC2 instance."
                fi
                return 0
            else
                warning "SSM command status: ${COMMAND_STATUS}"
                log "Falling back to SSH method..."
            fi
        else
            warning "Failed to send SSM command. Falling back to SSH method..."
        fi
    fi
    
    # Fallback to SSH method
    log "SSM not available or failed. Using SSH method..."
    
    # Create helper script for SSH copy
    cat > /tmp/copy-aws-profile.sh << 'COPY_SCRIPT'
#!/bin/bash
# Helper script to copy AWS profile to EC2 via SSH
# Usage: ./copy-aws-profile.sh [SSH_KEY_PATH] [SSH_USER]

SSH_KEY="${1:-}"
SSH_USER="${2:-ec2-user}"
INSTANCE_IP="${INSTANCE_IP}"

if [ -z "$SSH_KEY" ]; then
    echo "Usage: $0 [SSH_KEY_PATH] [SSH_USER]"
    echo "Example: $0 ~/.ssh/my-key.pem ec2-user"
    exit 1
fi

echo "Copying AWS profile to EC2..."
echo "Instance: ${INSTANCE_IP}"
echo "User: ${SSH_USER}"
echo ""

# Create .aws directory on remote
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "mkdir -p ~/.aws && chmod 700 ~/.aws"

# Copy AWS config
if [ -f "${AWS_CONFIG_FILE}" ]; then
    echo "Copying AWS config..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "${AWS_CONFIG_FILE}" ${SSH_USER}@${INSTANCE_IP}:~/.aws/config
fi

# Copy AWS credentials
if [ -f "${AWS_CREDENTIALS_FILE}" ]; then
    echo "Copying AWS credentials..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "${AWS_CREDENTIALS_FILE}" ${SSH_USER}@${INSTANCE_IP}:~/.aws/credentials
fi

# Copy SSO cache if it exists
if [ -d "${AWS_CONFIG_DIR}/sso/cache" ]; then
    echo "Copying SSO cache..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "mkdir -p ~/.aws/sso/cache"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r "${AWS_CONFIG_DIR}/sso/cache/"* ${SSH_USER}@${INSTANCE_IP}:~/.aws/sso/cache/ 2>/dev/null || true
fi

# Set permissions
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "chmod 700 ~/.aws; chmod 600 ~/.aws/config ~/.aws/credentials 2>/dev/null || true"

echo ""
echo "Done! AWS profile copied to EC2."
echo ""
echo "To verify, SSH into the instance and run:"
echo "  ssh -i $SSH_KEY ${SSH_USER}@${INSTANCE_IP}"
echo "  aws sts get-caller-identity --profile ${AWS_PROFILE}"
COPY_SCRIPT
    
    # Inject variables into the helper script
    sed -i.bak "s|INSTANCE_IP=\"\${INSTANCE_IP}\"|INSTANCE_IP=\"${INSTANCE_IP}\"|g" /tmp/copy-aws-profile.sh
    sed -i.bak "s|AWS_CONFIG_FILE=\"\${AWS_CONFIG_FILE}\"|AWS_CONFIG_FILE=\"${AWS_CONFIG_FILE}\"|g" /tmp/copy-aws-profile.sh
    sed -i.bak "s|AWS_CREDENTIALS_FILE=\"\${AWS_CREDENTIALS_FILE}\"|AWS_CREDENTIALS_FILE=\"${AWS_CREDENTIALS_FILE}\"|g" /tmp/copy-aws-profile.sh
    sed -i.bak "s|AWS_CONFIG_DIR=\"\${AWS_CONFIG_DIR}\"|AWS_CONFIG_DIR=\"${AWS_CONFIG_DIR}\"|g" /tmp/copy-aws-profile.sh
    sed -i.bak "s|AWS_PROFILE=\"\${AWS_PROFILE}\"|AWS_PROFILE=\"${AWS_PROFILE}\"|g" /tmp/copy-aws-profile.sh
    rm -f /tmp/copy-aws-profile.sh.bak
    
    chmod +x /tmp/copy-aws-profile.sh
    
    echo ""
    warning "To copy AWS profile via SSH, run:"
    echo ""
    echo "  /tmp/copy-aws-profile.sh [YOUR_SSH_KEY.pem] [SSH_USER]"
    echo ""
    echo "Or manually:"
    echo ""
    echo "  # Copy AWS config"
    echo "  scp ${AWS_CONFIG_FILE} ec2-user@${INSTANCE_IP}:~/.aws/config"
    if [ -f "${AWS_CREDENTIALS_FILE}" ]; then
        echo ""
        echo "  # Copy AWS credentials"
        echo "  scp ${AWS_CREDENTIALS_FILE} ec2-user@${INSTANCE_IP}:~/.aws/credentials"
    fi
    if [ -d "${AWS_CONFIG_DIR}/sso/cache" ]; then
        echo ""
        echo "  # Copy SSO cache (for SSO profiles)"
        echo "  scp -r ${AWS_CONFIG_DIR}/sso ec2-user@${INSTANCE_IP}:~/.aws/"
    fi
    echo ""
    echo "  # Set permissions"
    echo "  ssh ec2-user@${INSTANCE_IP} 'chmod 700 ~/.aws; chmod 600 ~/.aws/config ~/.aws/credentials 2>/dev/null || true'"
    echo ""
}

# Check AWS profile on EC2 instance
check_aws_profile_on_ec2() {
    log "Checking AWS profile on EC2 instance: ${INSTANCE_ID} (${INSTANCE_IP})..."
    
    # Build check commands
    CHECK_COMMANDS=(
        "echo '=== AWS CLI Check ==='"
        "command -v aws >/dev/null 2>&1 && echo 'AWS CLI: Installed' || echo 'AWS CLI: Not installed'"
        "echo ''"
        "echo '=== AWS Config Check ==='"
        "[ -d ~/.aws ] && echo 'AWS directory: Exists' || echo 'AWS directory: Not found'"
        "[ -f ~/.aws/config ] && echo 'AWS config file: Exists' || echo 'AWS config file: Not found'"
        "[ -f ~/.aws/credentials ] && echo 'AWS credentials file: Exists' || echo 'AWS credentials file: Not found'"
        "echo ''"
        "echo '=== AWS Profile Check ==='"
    )
    
    # Add profile-specific checks
    if [ -n "${AWS_PROFILE}" ] && [ "${AWS_PROFILE}" != "default" ]; then
        CHECK_COMMANDS+=(
            "if [ -f ~/.aws/config ]; then"
            "  if grep -q '\\[profile ${AWS_PROFILE}\\]' ~/.aws/config || grep -q '\\[${AWS_PROFILE}\\]' ~/.aws/config; then"
            "    echo 'Profile ${AWS_PROFILE}: Found in config'"
            "  else"
            "    echo 'Profile ${AWS_PROFILE}: Not found in config'"
            "  fi"
            "else"
            "  echo 'Profile ${AWS_PROFILE}: Cannot check (config file missing)'"
            "fi"
        )
    fi
    
    CHECK_COMMANDS+=(
        "echo ''"
        "echo '=== AWS Identity Check ==='"
    )
    
    # Try to get caller identity with profile
    if [ -n "${AWS_PROFILE}" ] && [ "${AWS_PROFILE}" != "default" ]; then
        CHECK_COMMANDS+=(
            "if command -v aws >/dev/null 2>&1; then"
            "  echo 'Testing profile: ${AWS_PROFILE}'"
            "  if aws sts get-caller-identity --profile ${AWS_PROFILE} 2>&1; then"
            "    echo ''"
            "    echo 'Profile ${AWS_PROFILE}: Working ✓'"
            "  else"
            "    echo ''"
            "    echo 'Profile ${AWS_PROFILE}: Failed (may need SSO login or credentials refresh)'"
            "  fi"
            "else"
            "  echo 'AWS CLI not installed, cannot test profile'"
            "fi"
        )
    else
        CHECK_COMMANDS+=(
            "if command -v aws >/dev/null 2>&1; then"
            "  echo 'Testing default credentials:'"
            "  if aws sts get-caller-identity 2>&1; then"
            "    echo ''"
            "    echo 'Default credentials: Working ✓'"
            "  else"
            "    echo ''"
            "    echo 'Default credentials: Failed'"
            "  fi"
            "else"
            "  echo 'AWS CLI not installed, cannot test credentials'"
            "fi"
        )
    fi
    
    CHECK_COMMANDS+=(
        "echo ''"
        "echo '=== AWS Config Contents (first 20 lines) ==='"
        "[ -f ~/.aws/config ] && head -20 ~/.aws/config || echo 'Config file not found'"
    )
    
    # Try SSM first
    SSM_AVAILABLE=false
    if aws ssm describe-instance-information \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].InstanceId' \
        --output text 2>/dev/null | grep -q "${INSTANCE_ID}"; then
        SSM_AVAILABLE=true
    fi
    
    if [ "$SSM_AVAILABLE" = true ]; then
        log "Using SSM to check AWS profile..."
        
        # Convert commands array to JSON format for SSM
        COMMANDS_JSON="["
        for i in "${!CHECK_COMMANDS[@]}"; do
            if [ $i -gt 0 ]; then
                COMMANDS_JSON+=","
            fi
            # Escape double quotes and backslashes in the command
            ESCAPED_CMD=$(echo "${CHECK_COMMANDS[$i]}" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
            COMMANDS_JSON+="\"${ESCAPED_CMD}\""
        done
        COMMANDS_JSON+="]"
        
        # Send command via SSM
        COMMAND_ID=$(aws ssm send-command \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=${COMMANDS_JSON}" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)
        
        if [ -n "$COMMAND_ID" ] && [ "$COMMAND_ID" != "None" ]; then
            log "SSM command sent. Command ID: ${COMMAND_ID}"
            log "Waiting for command to complete..."
            sleep 5
            
            # Get command output
            OUTPUT=$(aws ssm get-command-invocation \
                --region ${REGION} \
                --profile ${AWS_PROFILE} \
                --command-id "${COMMAND_ID}" \
                --instance-id "${INSTANCE_ID}" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null)
            
            ERROR_OUTPUT=$(aws ssm get-command-invocation \
                --region ${REGION} \
                --profile ${AWS_PROFILE} \
                --command-id "${COMMAND_ID}" \
                --instance-id "${INSTANCE_ID}" \
                --query 'StandardErrorContent' \
                --output text 2>/dev/null)
            
            COMMAND_STATUS=$(aws ssm get-command-invocation \
                --region ${REGION} \
                --profile ${AWS_PROFILE} \
                --command-id "${COMMAND_ID}" \
                --instance-id "${INSTANCE_ID}" \
                --query 'Status' \
                --output text 2>/dev/null || echo "Failed")
            
            echo ""
            echo "=========================================="
            echo "  AWS Profile Check Results"
            echo "=========================================="
            echo ""
            if [ -n "$OUTPUT" ]; then
                echo "$OUTPUT"
            fi
            if [ -n "$ERROR_OUTPUT" ] && [ "$ERROR_OUTPUT" != "None" ]; then
                echo "Errors:"
                echo "$ERROR_OUTPUT"
            fi
            echo ""
            echo "Command Status: ${COMMAND_STATUS}"
            echo ""
            
            if [ "$COMMAND_STATUS" = "Success" ]; then
                success "AWS profile check completed"
            else
                warning "AWS profile check completed with status: ${COMMAND_STATUS}"
            fi
            
            return 0
        else
            warning "Failed to send SSM command. Falling back to SSH method..."
        fi
    fi
    
    # Fallback to SSH method
    log "SSM not available. Using SSH method..."
    echo ""
    warning "To check AWS profile via SSH, run:"
    echo ""
    echo "  ssh ec2-user@${INSTANCE_IP} 'bash -s' << 'EOF'"
    for cmd in "${CHECK_COMMANDS[@]}"; do
        echo "  $cmd"
    done
    echo "  EOF"
    echo ""
    echo "Or use the helper script:"
    echo "  /tmp/check-aws-profile.sh [YOUR_SSH_KEY.pem] [SSH_USER]"
    echo ""
    
    # Create helper script with variables already injected
    cat > /tmp/check-aws-profile.sh << CHECK_SCRIPT_EOF
#!/bin/bash
# Helper script to check AWS profile on EC2 via SSH
# Usage: ./check-aws-profile.sh [SSH_KEY_PATH] [SSH_USER]

SSH_KEY="\${1:-}"
SSH_USER="\${2:-ec2-user}"
INSTANCE_IP="${INSTANCE_IP}"
AWS_PROFILE="${AWS_PROFILE}"

if [ -z "\$SSH_KEY" ]; then
    echo "Usage: \$0 [SSH_KEY_PATH] [SSH_USER]"
    echo "Example: \$0 ~/.ssh/my-key.pem ec2-user"
    exit 1
fi

echo "Checking AWS profile on EC2..."
echo "Instance: \${INSTANCE_IP}"
echo "User: \${SSH_USER}"
echo "Profile: \${AWS_PROFILE:-default}"
echo ""

ssh -i "\$SSH_KEY" -o StrictHostKeyChecking=no \${SSH_USER}@\${INSTANCE_IP} bash << REMOTE_CHECK_EOF
PROFILE_TO_CHECK="${AWS_PROFILE}"
echo "=== AWS CLI Check ==="
command -v aws >/dev/null 2>&1 && echo "AWS CLI: Installed" || echo "AWS CLI: Not installed"
echo ""
echo "=== AWS Config Check ==="
[ -d ~/.aws ] && echo "AWS directory: Exists" || echo "AWS directory: Not found"
[ -f ~/.aws/config ] && echo "AWS config file: Exists" || echo "AWS config file: Not found"
[ -f ~/.aws/credentials ] && echo "AWS credentials file: Exists" || echo "AWS credentials file: Not found"
echo ""
echo "=== AWS Profile Check ==="
if [ -f ~/.aws/config ]; then
  if grep -q "\[profile \${PROFILE_TO_CHECK}\]" ~/.aws/config 2>/dev/null || grep -q "\[\${PROFILE_TO_CHECK}\]" ~/.aws/config 2>/dev/null; then
    echo "Profile \${PROFILE_TO_CHECK}: Found in config"
  else
    echo "Profile \${PROFILE_TO_CHECK}: Not found in config"
  fi
else
  echo "Profile \${PROFILE_TO_CHECK}: Cannot check (config file missing)"
fi
echo ""
echo "=== AWS Identity Check ==="
if command -v aws >/dev/null 2>&1; then
  if [ -n "\${PROFILE_TO_CHECK}" ] && [ "\${PROFILE_TO_CHECK}" != "default" ]; then
    echo "Testing profile: \${PROFILE_TO_CHECK}"
    aws sts get-caller-identity --profile \${PROFILE_TO_CHECK} 2>&1
  else
    echo "Testing default credentials:"
    aws sts get-caller-identity 2>&1
  fi
else
  echo "AWS CLI not installed, cannot test credentials"
fi
echo ""
echo "=== AWS Config Contents (first 20 lines) ==="
[ -f ~/.aws/config ] && head -20 ~/.aws/config || echo "Config file not found"
REMOTE_CHECK_EOF

echo ""
echo "Done!"
CHECK_SCRIPT_EOF
    
    chmod +x /tmp/check-aws-profile.sh
    log "Helper script created at: /tmp/check-aws-profile.sh"
}

# Find SSH key for the instance
find_ssh_key() {
    # If SSH_KEY is already set, use it
    if [ -n "${SSH_KEY}" ] && [ -f "${SSH_KEY}" ]; then
        log "Using provided SSH key: ${SSH_KEY}"
        return 0
    fi
    
    # Try to get key pair name from instance
    KEY_NAME=$(aws ec2 describe-instances \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --instance-ids ${INSTANCE_ID} \
        --query 'Reservations[0].Instances[0].KeyName' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "${KEY_NAME}" ] && [ "${KEY_NAME}" != "None" ] && [ "${KEY_NAME}" != "null" ]; then
        log "Instance uses key pair: ${KEY_NAME}"
        
        # Try common locations for the key file
        KEY_LOCATIONS=(
            "${KEY_NAME}.pem"
            "~/.ssh/${KEY_NAME}.pem"
            "~/.ssh/${KEY_NAME}"
            "./${KEY_NAME}.pem"
            "${HOME}/.ssh/${KEY_NAME}.pem"
            "${HOME}/.ssh/${KEY_NAME}"
        )
        
        for key_loc in "${KEY_LOCATIONS[@]}"; do
            # Expand ~ to home directory
            expanded_key=$(echo "${key_loc}" | sed "s|^~|${HOME}|")
            if [ -f "${expanded_key}" ]; then
                SSH_KEY="${expanded_key}"
                log "Found SSH key: ${SSH_KEY}"
                return 0
            fi
        done
        
        warning "Key pair '${KEY_NAME}' found but key file not found in common locations"
        log "Please set SSH_KEY environment variable or place key at: ${KEY_NAME}.pem"
    else
        log "No key pair associated with instance (may use SSM only)"
    fi
    
    return 1
}

# Deploy to EC2 instance
deploy_to_instance() {
    log "Deploying to EC2 instance: ${INSTANCE_ID} (${INSTANCE_IP})..."
    
    # Create deployment script for remote execution
    cat > /tmp/deploy-remote.sh << REMOTE_SCRIPT
#!/bin/bash
set -e

ECR_REGISTRY="517569678285.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPOSITORY="image-annotation-app"
IMAGE_TAG="\${1:-latest}"
CONTAINER_NAME="image-annotation-app"
APP_PORT="\${2:-5000}"
HOST_PORT="\${3:-5000}"
AWS_PROFILE="${AWS_PROFILE}"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    
    # Detect OS distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=\$ID
    else
        OS="unknown"
    fi
    
    # Install Docker based on OS
    case \$OS in
        amzn|amazon)
            echo "Detected Amazon Linux. Installing Docker via yum..."
            sudo yum update -y
            sudo yum install -y docker
            sudo systemctl start docker
            sudo systemctl enable docker
            sudo usermod -aG docker \$USER
            ;;
        ubuntu|debian)
            echo "Detected Ubuntu/Debian. Installing Docker..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker \$USER
            rm get-docker.sh
            ;;
        *)
            echo "Unknown OS. Trying generic Docker installation..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh || {
                echo "Generic installation failed. Please install Docker manually."
                exit 1
            }
            sudo usermod -aG docker \$USER
            rm get-docker.sh
            ;;
    esac
    
    echo "Docker installation completed"
fi

# Start Docker service
sudo systemctl start docker || true
sudo systemctl enable docker || true

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
fi

# Authenticate with ECR
echo "Authenticating with ECR..."
ECR_LOGIN_SUCCESS=false

# Debug: Check what credentials are available
echo "Checking available AWS credentials..."
echo "AWS_PROFILE: \${AWS_PROFILE:-not set}"

# Check if credentials file exists and has content
if [ -f ~/.aws/credentials ]; then
    echo "AWS credentials file exists"
    if [ -s ~/.aws/credentials ]; then
        echo "Credentials file has content"
        # Show first line (without sensitive data)
        echo "Credentials file preview (first line): \$(head -1 ~/.aws/credentials | cut -d'=' -f1)"
    else
        echo "Credentials file is empty"
    fi
else
    echo "AWS credentials file does not exist"
fi

# Check if config file exists
if [ -f ~/.aws/config ]; then
    echo "AWS config file exists"
else
    echo "AWS config file does not exist"
fi

# First, try default credentials (from credentials file or IAM role)
if [ -f ~/.aws/credentials ] && [ -s ~/.aws/credentials ]; then
    echo "Trying default credentials from credentials file..."
    if aws sts get-caller-identity >/dev/null 2>&1; then
        CALLER_IDENTITY=\$(aws sts get-caller-identity --output json 2>/dev/null)
        echo "Default credentials are valid"
        echo "Caller identity: \$(echo "\$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | head -1 || echo 'unknown')"
        echo "Attempting ECR login..."
        if aws ecr get-login-password --region us-east-1 2>&1 | sudo docker login --username AWS --password-stdin \${ECR_REGISTRY} 2>&1; then
            echo "ECR authentication successful using default credentials"
            ECR_LOGIN_SUCCESS=true
        else
            echo "ECR authentication with default credentials failed"
            echo "Testing ECR access:"
            aws ecr get-login-password --region us-east-1 2>&1 | head -3 || true
        fi
    else
        echo "Default credentials are not valid"
        echo "Error: \$(aws sts get-caller-identity 2>&1 | head -3 || echo 'unknown error')"
    fi
fi

# Try with profile if default credentials didn't work
if [ "\${ECR_LOGIN_SUCCESS}" = "false" ] && [ -f ~/.aws/config ] && [ -n "\${AWS_PROFILE}" ]; then
    echo "AWS config file exists, checking profile \${AWS_PROFILE}..."
    # Check if profile uses SSO
    if grep -A 5 "\[profile \${AWS_PROFILE}\]" ~/.aws/config 2>/dev/null | grep -q "sso_"; then
        echo "Profile \${AWS_PROFILE} uses SSO - trying default credentials instead..."
    else
        echo "Profile \${AWS_PROFILE} does not use SSO, attempting to use it..."
        if aws sts get-caller-identity --profile \${AWS_PROFILE} >/dev/null 2>&1; then
            echo "Profile \${AWS_PROFILE} is valid, attempting ECR login..."
            if aws ecr get-login-password --region us-east-1 --profile \${AWS_PROFILE} 2>&1 | sudo docker login --username AWS --password-stdin \${ECR_REGISTRY} 2>&1; then
                echo "ECR authentication successful using profile \${AWS_PROFILE}"
                ECR_LOGIN_SUCCESS=true
            else
                echo "ECR authentication with profile failed"
            fi
        else
            echo "Profile \${AWS_PROFILE} authentication failed"
        fi
    fi
fi

# Try with IAM role if nothing else worked
if [ "\${ECR_LOGIN_SUCCESS}" = "false" ]; then
    echo "Attempting to use IAM role (instance profile)..."
    # Check if we can get caller identity (tests IAM role)
    if aws sts get-caller-identity >/dev/null 2>&1; then
        echo "IAM role is available, attempting ECR login..."
        if aws ecr get-login-password --region us-east-1 2>&1 | sudo docker login --username AWS --password-stdin \${ECR_REGISTRY} 2>&1; then
            echo "ECR authentication successful using IAM role"
            ECR_LOGIN_SUCCESS=true
        else
            echo "ECR authentication with IAM role failed"
            echo "Error details:"
            aws ecr get-login-password --region us-east-1 2>&1 | head -5 || true
        fi
    else
        echo "IAM role not available or not configured"
    fi
fi

# Final check
if [ "\${ECR_LOGIN_SUCCESS}" = "false" ]; then
    echo ""
    echo "ERROR: ECR authentication failed"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. If using SSO profile, ensure temporary credentials were copied to ~/.aws/credentials"
    echo "  2. Attach an IAM role to the EC2 instance with ECR permissions:"
    echo "     - ecr:GetAuthorizationToken"
    echo "     - ecr:BatchCheckLayerAvailability"
    echo "     - ecr:GetDownloadUrlForLayer"
    echo "     - ecr:BatchGetImage"
    echo ""
    echo "  3. Check credentials:"
    echo "     aws sts get-caller-identity"
    echo "     aws ecr describe-repositories --region us-east-1"
    echo ""
    exit 1
fi

# Create directories
sudo mkdir -p /opt/image-annotation-app/{uploads,instance,logs}
sudo chown -R 1000:1000 /opt/image-annotation-app

# Ensure AWS config directory exists and get absolute path
AWS_DIR=""
if [ -d ~/.aws ]; then
    AWS_DIR=\$(cd ~/.aws && pwd)
    echo "AWS config directory found at: \${AWS_DIR}"
    echo "Will mount to container at /root/.aws (read-only)"
else
    echo "Warning: AWS config directory not found. Container may not have AWS access."
fi

# Stop and remove existing container
sudo docker stop ${CONTAINER_NAME} 2>/dev/null || true
sudo docker rm ${CONTAINER_NAME} 2>/dev/null || true

# Pull and run container
sudo docker pull ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}

# Build docker run command with AWS profile support
DOCKER_CMD="sudo docker run -d \
    --name ${CONTAINER_NAME} \
    --restart unless-stopped \
    -p ${HOST_PORT}:${APP_PORT} \
    -v /opt/image-annotation-app/uploads:/app/uploads \
    -v /opt/image-annotation-app/instance:/app/instance \
    -v /opt/image-annotation-app/logs:/app/logs \
    -e FLASK_ENV=production \
    -e PYTHONUNBUFFERED=1"

# Add AWS profile environment variable and mount if set
if [ -n "\${AWS_PROFILE}" ]; then
    echo "Configuring container to use AWS profile: \${AWS_PROFILE}"
    DOCKER_CMD="\${DOCKER_CMD} -e AWS_PROFILE=\${AWS_PROFILE}"
    
    # Mount AWS config directory if it exists
    if [ -n "\${AWS_DIR}" ]; then
        DOCKER_CMD="\${DOCKER_CMD} -v \${AWS_DIR}:/root/.aws:ro"
        echo "Mounted AWS config directory to container (read-only)"
    else
        echo "Warning: ~/.aws directory not found. AWS profile may not work in container."
    fi
else
    echo "No AWS profile specified, container will use default AWS credentials (IAM role if available)"
fi

# Add image name and execute
DOCKER_CMD="\${DOCKER_CMD} ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "Running: \${DOCKER_CMD}"
eval \${DOCKER_CMD}

echo "Deployment completed!"
echo "Container: ${CONTAINER_NAME}"
echo "Access: http://\$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo 'INSTANCE_IP'):${HOST_PORT}"
REMOTE_SCRIPT

    # Try SSM first
    log "Attempting to use AWS Systems Manager (if available)..."
    SSM_AVAILABLE=false
    if aws ssm describe-instance-information \
        --region ${REGION} \
        --profile ${AWS_PROFILE} \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].InstanceId' \
        --output text 2>/dev/null | grep -q "${INSTANCE_ID}"; then
        SSM_AVAILABLE=true
        log "Instance has SSM agent. Sending deployment command..."
        
        # Encode the deployment script
        DEPLOY_SCRIPT_B64=$(base64 -i /tmp/deploy-remote.sh 2>/dev/null || base64 /tmp/deploy-remote.sh)
        
        COMMAND_ID=$(aws ssm send-command \
            --region ${REGION} \
            --profile ${AWS_PROFILE} \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[\"echo '${DEPLOY_SCRIPT_B64}' | base64 -d | bash\"]" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)
        
        if [ -n "$COMMAND_ID" ] && [ "$COMMAND_ID" != "None" ]; then
            log "SSM command sent. Command ID: ${COMMAND_ID}"
            log "Waiting for deployment to complete..."
            sleep 5
            
            # Check command status
            COMMAND_STATUS=$(aws ssm get-command-invocation \
                --region ${REGION} \
                --profile ${AWS_PROFILE} \
                --command-id "${COMMAND_ID}" \
                --instance-id "${INSTANCE_ID}" \
                --query 'Status' \
                --output text 2>/dev/null || echo "InProgress")
            
            if [ "$COMMAND_STATUS" = "Success" ]; then
                success "Deployment completed via SSM!"
                return 0
            else
                log "SSM command status: ${COMMAND_STATUS} (may still be running)"
                log "Check status with: aws ssm get-command-invocation --command-id ${COMMAND_ID} --instance-id ${INSTANCE_ID} --region ${REGION} --profile ${AWS_PROFILE}"
            fi
        else
            warning "SSM command failed. Trying SSH method..."
            SSM_AVAILABLE=false
        fi
    else
        warning "SSM not available. Trying SSH method..."
    fi
    
    # Fallback to SSH if SSM failed or not available
    if [ "$SSM_AVAILABLE" = false ]; then
        log "Attempting SSH-based deployment..."
        
        # Try to find SSH key
        if find_ssh_key; then
            log "Deploying via SSH using key: ${SSH_KEY}"
            
            # Determine SSH user based on AMI (Amazon Linux uses ec2-user, Ubuntu uses ubuntu)
            # Try ec2-user first (Amazon Linux)
            if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${SSH_USER}@${INSTANCE_IP} "echo 'test'" >/dev/null 2>&1; then
                log "SSH connection successful as ${SSH_USER}"
            else
                # Try ubuntu user
                if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${INSTANCE_IP} "echo 'test'" >/dev/null 2>&1; then
                    SSH_USER="ubuntu"
                    log "SSH connection successful as ubuntu"
                else
                    error "SSH connection failed. Please check:"
                    echo "  1. SSH key is correct: ${SSH_KEY}"
                    echo "  2. Security group allows SSH (port 22)"
                    echo "  3. Instance is running and accessible"
                    return 1
                fi
            fi
            
            # Ensure AWS profile is copied to instance if needed
            if [ -n "${AWS_PROFILE}" ]; then
                log "Ensuring AWS profile is available on instance..."
                ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "mkdir -p ~/.aws && chmod 700 ~/.aws" || true
                
                # Check if profile uses SSO
                IS_SSO_PROFILE=false
                if [ -f "${HOME}/.aws/config" ]; then
                    if grep -A 5 "\[profile ${AWS_PROFILE}\]" "${HOME}/.aws/config" 2>/dev/null | grep -q "sso_"; then
                        IS_SSO_PROFILE=true
                        log "Detected SSO profile. Getting temporary credentials from local session..."
                        
                        # Get temporary credentials from local SSO session
                        log "Extracting temporary credentials from local SSO session..."
                        
                        # Try multiple methods to get credentials
                        CREDS_ENV=""
                        
                        # Method 1: Try export-credentials (AWS CLI v2)
                        if aws configure export-credentials --profile ${AWS_PROFILE} --format env >/dev/null 2>&1; then
                            CREDS_ENV=$(aws configure export-credentials --profile ${AWS_PROFILE} --format env 2>/dev/null)
                            log "Got credentials using export-credentials method"
                        fi
                        
                        # Method 2: Try to get from SSO cache and create credentials manually
                        if [ -z "$CREDS_ENV" ]; then
                            log "Trying alternative method to get SSO credentials..."
                            # Check SSO cache directory
                            SSO_CACHE_DIR="${HOME}/.aws/sso/cache"
                            if [ -d "$SSO_CACHE_DIR" ]; then
                                # Try to get credentials using boto3 session (if python is available)
                                CREDS_JSON=$(python3 -c "
import boto3
import json
from botocore.exceptions import ProfileNotFound
try:
    session = boto3.Session(profile_name='${AWS_PROFILE}')
    creds = session.get_credentials()
    if creds:
        print(json.dumps({
            'AWS_ACCESS_KEY_ID': creds.access_key,
            'AWS_SECRET_ACCESS_KEY': creds.secret_key,
            'AWS_SESSION_TOKEN': creds.token
        }))
except Exception as e:
    pass
" 2>/dev/null)
                                
                                if [ -n "$CREDS_JSON" ]; then
                                    ACCESS_KEY=$(echo "$CREDS_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['AWS_ACCESS_KEY_ID'])" 2>/dev/null)
                                    SECRET_KEY=$(echo "$CREDS_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['AWS_SECRET_ACCESS_KEY'])" 2>/dev/null)
                                    SESSION_TOKEN=$(echo "$CREDS_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['AWS_SESSION_TOKEN'])" 2>/dev/null)
                                    
                                    if [ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ] && [ -n "$SESSION_TOKEN" ]; then
                                        CREDS_ENV="AWS_ACCESS_KEY_ID=$ACCESS_KEY
AWS_SECRET_ACCESS_KEY=$SECRET_KEY
AWS_SESSION_TOKEN=$SESSION_TOKEN"
                                        log "Got credentials using boto3 method"
                                    fi
                                fi
                            fi
                        fi
                        
                        if [ -n "$CREDS_ENV" ]; then
                            # Parse the credentials
                            ACCESS_KEY=$(echo "$CREDS_ENV" | grep "AWS_ACCESS_KEY_ID" | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'")
                            SECRET_KEY=$(echo "$CREDS_ENV" | grep "AWS_SECRET_ACCESS_KEY" | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'")
                            SESSION_TOKEN=$(echo "$CREDS_ENV" | grep "AWS_SESSION_TOKEN" | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'")
                            
                            if [ -n "$ACCESS_KEY" ] && [ -n "$SECRET_KEY" ] && [ -n "$SESSION_TOKEN" ]; then
                                # Verify credentials are valid before copying
                                log "Verifying credentials are valid..."
                                if AWS_ACCESS_KEY_ID="$ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SECRET_KEY" AWS_SESSION_TOKEN="$SESSION_TOKEN" \
                                   aws sts get-caller-identity >/dev/null 2>&1; then
                                    log "Credentials are valid, creating credentials file..."
                                    # Create temporary credentials file
                                    cat > /tmp/aws-credentials-temp << TEMP_CREDS_EOF
[default]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${SESSION_TOKEN}
TEMP_CREDS_EOF
                                    
                                    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no /tmp/aws-credentials-temp ${SSH_USER}@${INSTANCE_IP}:~/.aws/credentials || {
                                        warning "Failed to copy temporary credentials"
                                    }
                                    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "chmod 600 ~/.aws/credentials" || true
                                    rm -f /tmp/aws-credentials-temp
                                    
                                    log "Temporary credentials from SSO session copied to instance"
                                else
                                    warning "Extracted credentials are not valid. Will try IAM role."
                                fi
                            else
                                warning "Could not parse credentials from SSO session. Will try IAM role."
                            fi
                        else
                            warning "Could not export credentials from SSO session. Will try IAM role."
                            warning "Note: For SSO profiles, the instance should have an IAM role with ECR permissions."
                            warning "Alternatively, ensure 'aws configure export-credentials' works or Python/boto3 is available."
                        fi
                    else
                        # Non-SSO profile, copy config and credentials normally
                        log "Copying AWS config to instance..."
                        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${HOME}/.aws/config" ${SSH_USER}@${INSTANCE_IP}:~/.aws/config || {
                            warning "Failed to copy AWS config, will try IAM role"
                        }
                        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "chmod 600 ~/.aws/config" || true
                        
                        # Copy AWS credentials if they exist locally
                        if [ -f "${HOME}/.aws/credentials" ]; then
                            log "Copying AWS credentials to instance..."
                            scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${HOME}/.aws/credentials" ${SSH_USER}@${INSTANCE_IP}:~/.aws/credentials || {
                                warning "Failed to copy AWS credentials, will try IAM role"
                            }
                            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "chmod 600 ~/.aws/credentials" || true
                        fi
                    fi
                fi
            fi
            
            # Copy deployment script to instance
            log "Copying deployment script to instance..."
            scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no /tmp/deploy-remote.sh ${SSH_USER}@${INSTANCE_IP}:/tmp/deploy-remote.sh || {
                error "Failed to copy deployment script"
                return 1
            }
            
            # Execute deployment script
            log "Executing deployment on instance..."
            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP} "chmod +x /tmp/deploy-remote.sh && /tmp/deploy-remote.sh ${IMAGE_TAG} ${APP_PORT} ${HOST_PORT}" || {
                error "Deployment failed"
                return 1
            }
            
            success "Deployment completed via SSH!"
            return 0
        else
            warning "SSH key not found. Manual deployment required."
            echo ""
            echo "To deploy manually:"
            echo "1. Set SSH_KEY environment variable:"
            echo "   export SSH_KEY=/path/to/your-key.pem"
            echo "   $0 ${IMAGE_TAG} ${APP_PORT} ${HOST_PORT}"
            echo ""
            echo "2. Or manually SSH and run:"
            echo "   ssh -i YOUR_KEY.pem ${SSH_USER}@${INSTANCE_IP}"
            echo "   # Then copy and run /tmp/deploy-remote.sh"
            echo ""
            echo "The deployment script is saved at: /tmp/deploy-remote.sh"
            return 1
        fi
    fi
}

# Main function
main() {
    echo "=========================================="
    echo "  Deploy image-annotation-app to EC2"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  ECR Registry: ${ECR_REGISTRY}"
    echo "  Repository: ${ECR_REPOSITORY}"
    echo "  Image Tag: ${IMAGE_TAG}"
    echo "  Instance Type: ${INSTANCE_TYPE}"
    echo "  Region: ${REGION}"
    echo "  Container Port: ${APP_PORT}"
    echo "  Host Port: ${HOST_PORT}"
    echo "  AWS Profile: ${AWS_PROFILE} (will be passed to container)"
    echo ""
    
    check_aws_cli
    check_aws_sso
    get_or_create_instance
    check_and_attach_iam_role "ec2-s3-access"
    share_aws_profile
    deploy_to_instance
    
    echo ""
    success "Deployment process initiated!"
    echo "Instance ID: ${INSTANCE_ID}"
    echo "Instance IP: ${INSTANCE_IP}"
    echo "Access URL: http://${INSTANCE_IP}:${HOST_PORT}"
    if [ -n "${AWS_PROFILE}" ]; then
        echo "AWS Profile: ${AWS_PROFILE} (configured in container)"
    fi
    echo ""
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS] [IMAGE_TAG] [APP_PORT] [HOST_PORT]"
        echo ""
        echo "Deploys image-annotation-app to EC2 t3.small instance in us-east-1"
        echo ""
        echo "Options:"
        echo "  --check-profile    Check AWS profile configuration on EC2 instance"
        echo "  --help, -h         Show this help message"
        echo ""
        echo "Arguments:"
        echo "  IMAGE_TAG    Docker image tag (default: latest)"
        echo "  APP_PORT     Container port (default: 5000)"
        echo "  HOST_PORT    Host port (default: 5000)"
        echo ""
        echo "Environment Variables:"
        echo "  AWS_PROFILE  AWS profile to use (default: default)"
        echo "  SSH_KEY      Path to SSH private key for EC2 instance (optional)"
        echo "  SSH_USER     SSH username (default: ec2-user)"
        echo ""
        echo "Examples:"
        echo "  $0                                    # Deploy with default settings"
        echo "  $0 v1.0.0                             # Deploy with specific image tag"
        echo "  $0 --check-profile                    # Check AWS profile on EC2"
        echo "  AWS_PROFILE=myprofile $0              # Use specific AWS profile"
        echo "  SSH_KEY=~/.ssh/my-key.pem $0          # Deploy via SSH with key"
        echo "  AWS_PROFILE=myprofile SSH_KEY=~/.ssh/my-key.pem $0  # Both options"
        exit 0
        ;;
    --check-profile)
        echo "=========================================="
        echo "  Check AWS Profile on EC2"
        echo "=========================================="
        echo ""
        check_aws_cli
        check_aws_sso
        get_or_create_instance
        check_and_attach_iam_role "ec2-s3-access"
        check_aws_profile_on_ec2
        exit 0
        ;;
    *)
        main
        ;;
esac

