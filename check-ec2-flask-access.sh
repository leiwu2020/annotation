#!/bin/bash
# check-ec2-flask-access.sh
# Usage: bash check-ec2-flask-access.sh <EC2_PUBLIC_IP> [PORT]

set -e

EC2_IP="$1"
PORT="${2:-5000}"
KEY_PATH="annotation-key-mumbai.pem"

if [ -z "$EC2_IP" ]; then
  echo "Usage: $0 <EC2_PUBLIC_IP> [PORT]"
  exit 1
fi

# 1. Check if port is open from local machine

echo "[1] Checking if port $PORT is open on $EC2_IP from this machine..."
if nc -z -w 3 "$EC2_IP" "$PORT"; then
  echo "[OK] Port $PORT is open on $EC2_IP."
else
  echo "[FAIL] Port $PORT is NOT open on $EC2_IP."
  echo "Possible reasons:"
  echo "  - Security group does not allow inbound $PORT."
  echo "  - Instance is not running, or no public IP."
  echo "  - Network ACL or VPC/subnet misconfiguration."
fi

# 2. Try SSH to instance

echo "[2] Checking SSH access to $EC2_IP..."
if ssh -i "$KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$EC2_IP" 'echo SSH OK'; then
  echo "[OK] SSH access works."
else
  echo "[FAIL] Cannot SSH to $EC2_IP."
  echo "Check key, instance state, and security group (port 22)."
  exit 1
fi

# 3. Check if Flask app is running and listening on 0.0.0.0:$PORT

echo "[3] Checking if Flask app is running and listening on $PORT..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$EC2_IP" "ps aux | grep '[p]ython' && sudo netstat -tuln | grep :$PORT || sudo ss -tuln | grep :$PORT"

# 4. Check app log for errors

echo "[4] Checking app.log for errors..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$EC2_IP" "tail -n 40 app.log || echo 'No app.log found.'"

echo "[Done]"
