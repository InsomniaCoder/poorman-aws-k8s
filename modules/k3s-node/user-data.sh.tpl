#!/bin/bash
set -euo pipefail

REGION="${region}"
EIP_ALLOC="${eip_allocation_id}"
VOLUME_ID="${data_volume_id}"
XVDF_DEVICE="/dev/xvdf"
MOUNT_POINT="/var/lib/rancher/k3s"
EIP_PUBLIC="${eip_public_ip}"
SSM_TOKEN_PATH="${ssm_token_path}"
SSM_SERVER_IP_PATH="${ssm_server_ip_path}"

# IMDSv2 — ec2-metadata CLI is not present on AL2023
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# 1. Reassociate EIP so traffic routes to this instance immediately
aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "$EIP_ALLOC" \
  --allow-reassociation \
  --region "$REGION"

# 2. Attach the persistent K3S data volume
aws ec2 attach-volume \
  --volume-id "$VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device "$XVDF_DEVICE" \
  --region "$REGION"

# Nitro instances (Graviton m7g/m6g/t4g) expose EBS as NVMe.
# Use the volume ID symlink under /dev/disk/by-id/ for deterministic identification.
# The symlink is: nvme-Amazon_Elastic_Block_Store_<vol-id-without-dashes>
VOL_ID_SHORT="$${VOLUME_ID##vol-}"
SYMLINK="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$VOL_ID_SHORT"
DEVICE=""
for i in $(seq 1 60); do
  if [ -L "$SYMLINK" ]; then DEVICE=$(readlink -f "$SYMLINK"); break; fi
  if [ -b "$XVDF_DEVICE" ]; then DEVICE="$XVDF_DEVICE"; break; fi
  sleep 1
done
if [ -z "$DEVICE" ]; then
  echo "ERROR: data volume $${VOLUME_ID} did not appear after 60s" >&2
  exit 1
fi

# 3. Format only if no filesystem exists (first boot)
if ! blkid "$DEVICE" &>/dev/null; then
  mkfs.ext4 "$DEVICE"
fi

# 4. Mount
mkdir -p "$MOUNT_POINT"
mount "$DEVICE" "$MOUNT_POINT"

# Persist mount across reboots
echo "$DEVICE  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab

# 5. Install K3S — taint prevents workload pods from scheduling on the server
INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_EXEC="server --node-external-ip $EIP_PUBLIC --advertise-address $PRIVATE_IP --tls-san $EIP_PUBLIC --write-kubeconfig-mode 644 --node-taint CriticalAddonsOnly=true:NoExecute --disable traefik" \
  sh /usr/local/share/k3s-install.sh

# 6. Publish cluster join info to SSM so worker nodes can self-bootstrap
# K3s writes node-token during etcd bootstrap — wait up to 120s
TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
for i in $(seq 1 60); do
  [ -f "$TOKEN_FILE" ] && break
  sleep 2
done
if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: K3s did not write node-token within 120s" >&2
  exit 1
fi
K3S_TOKEN=$(cat "$TOKEN_FILE")
aws ssm put-parameter \
  --name "$SSM_TOKEN_PATH" \
  --value "$K3S_TOKEN" \
  --type "SecureString" \
  --overwrite \
  --region "$REGION"

aws ssm put-parameter \
  --name "$SSM_SERVER_IP_PATH" \
  --value "$PRIVATE_IP" \
  --type "String" \
  --overwrite \
  --region "$REGION"
