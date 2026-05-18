#!/bin/bash
set -euo pipefail

REGION="${region}"
SSM_TOKEN_PATH="${ssm_token_path}"
SSM_SERVER_IP_PATH="${ssm_server_ip_path}"

# 1. Read K3S join info from SSM — retry until server has written them (up to 5 min)
K3S_TOKEN=""
for i in $(seq 1 60); do
  K3S_TOKEN=$(aws ssm get-parameter \
    --name "$SSM_TOKEN_PATH" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION" 2>/dev/null) && [ -n "$K3S_TOKEN" ] && break
  sleep 5
done
if [ -z "$K3S_TOKEN" ]; then
  echo "ERROR: K3S token not available in SSM after 5 min" >&2
  exit 1
fi

K3S_SERVER_IP=$(aws ssm get-parameter \
  --name "$SSM_SERVER_IP_PATH" \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

# 2. Install K3S as agent — joins the server over private IP
INSTALL_K3S_SKIP_DOWNLOAD=true \
  K3S_URL="https://$K3S_SERVER_IP:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh /usr/local/share/k3s-install.sh
