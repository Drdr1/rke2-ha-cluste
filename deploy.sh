#!/bin/bash

set -e

# Log file for debugging
LOG_FILE="deploy.log"
echo "Deployment started at $(date)" > "$LOG_FILE"

# Load values from values.yaml
NODE_COUNT=$(grep "nodeCount:" values.yaml | awk '{print $2}')
STATIC_IPS=($(grep -A $NODE_COUNT "staticIps:" values.yaml | tail -n $NODE_COUNT | awk '{print $2}' | tr -d '"'))
CLUSTER_DOMAIN=$(grep "clusterDomain:" values.yaml | awk '{print $2}' | tr -d '"')
VIP=$(grep "vip:" values.yaml | awk '{print $2}' | tr -d '"')
DOMAIN=$(grep "domain:" values.yaml | awk '{print $2}' | tr -d '"')

# Validate inputs
if [ -z "$NODE_COUNT" ] || [ ${#STATIC_IPS[@]} -ne "$NODE_COUNT" ] || [ -z "$CLUSTER_DOMAIN" ] || [ -z "$VIP" ] || [ -z "$DOMAIN" ]; then
  echo "Error: Please ensure values.yaml contains nodeCount, staticIps (matching nodeCount), clusterDomain, vip, and domain." | tee -a "$LOG_FILE"
  exit 1
fi

# Check for certificates
for CERT in abc.cert abc.key cacerts.pem; do
  if [ ! -f "$CERT" ]; then
    echo "Error: Certificate file $CERT not found in current directory." | tee -a "$LOG_FILE"
    exit 1
  fi
done

# Validate SSH access and network connectivity
echo "Validating SSH access and network connectivity..." | tee -a "$LOG_FILE"
for IP in "${STATIC_IPS[@]}"; do
  if ! ping -c 3 "$IP" > /dev/null 2>&1; then
    echo "Warning: Cannot ping $IP, proceeding anyway..." | tee -a "$LOG_FILE"
  fi
  if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$IP" "echo SSH test" > /dev/null 2>&1; then
    echo "Error: Cannot SSH to $IP. Ensure SSH keys are set up and the ubuntu user has access." | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "Validated $IP" | tee -a "$LOG_FILE"
done

# Package the Helm chart
helm package . >> "$LOG_FILE" 2>&1
CHART_TGZ="rke2-ha-cluster-0.1.0.tgz"

# Serve the chart temporarily
echo "Starting temporary HTTP server on port 8000..." | tee -a "$LOG_FILE"
python3 -m http.server 8000 &
SERVER_PID=$!
sleep 2  # Wait for server to start

# Function to deploy to a node
deploy_to_node() {
  local NODE_IP=$1
  local NODE_NUM=$2
  local WORKSTATION_IP=$(hostname -I | awk '{print $1}')
  echo "Deploying to node $NODE_NUM ($NODE_IP)..." | tee -a "$LOG_FILE"

  ssh -o StrictHostKeyChecking=no ubuntu@"$NODE_IP" << EOF >> "$LOG_FILE" 2>&1
    sudo mkdir -p /etc/rancher/rke2-config-rke2-ha
    sudo curl -L http://$WORKSTATION_IP:8000/$CHART_TGZ | tar xz -C /tmp
    sudo cp /tmp/rke2-ha-cluster/templates/rke2-config.yaml /etc/rancher/rke2-config-rke2-ha/config.yaml
    sudo bash /tmp/rke2-ha-cluster/templates/install.sh
    rm -rf /tmp/rke2-ha-cluster
EOF

  if [ $? -eq 0 ]; then
    echo "Node $NODE_NUM deployed successfully." | tee -a "$LOG_FILE"
  else
    echo "Error deploying to node $NODE_NUM. Check $LOG_FILE for details." | tee -a "$LOG_FILE"
    exit 1
  fi
}

# Deploy to first node
deploy_to_node "${STATIC_IPS[0]}" 1
echo "Waiting for first node to initialize (60 seconds)..." | tee -a "$LOG_FILE"
sleep 60  # Increased wait time for stability

# Deploy to remaining nodes in parallel
PIDS=()
for i in $(seq 1 $((NODE_COUNT - 1))); do
  deploy_to_node "${STATIC_IPS[$i]}" $((i + 1)) &
  PIDS+=($!)
done

# Wait for all parallel deployments to complete
for PID in "${PIDS[@]}"; do
  wait "$PID"
done

# Install Rancher on the first node
echo "Installing Rancher on first node (${STATIC_IPS[0]})..." | tee -a "$LOG_FILE"
scp abc.cert abc.key cacerts.pem ubuntu@"${STATIC_IPS[0]}":/home/ubuntu/ >> "$LOG_FILE" 2>&1
ssh -o StrictHostKeyChecking=no ubuntu@"${STATIC_IPS[0]}" << EOF >> "$LOG_FILE" 2>&1
  sudo kubectl create ns cattle-system
  sudo kubectl -n cattle-system create secret tls tls-rancher-ingress --cert=/home/ubuntu/abc.cert --key=/home/ubuntu/abc.key
  sudo kubectl -n cattle-system create secret generic tls-ca --from-file=/home/ubuntu/cacerts.pem
  sudo helm repo add rancher-prime https://charts.rancher.com/server-charts/prime
  sudo helm upgrade -i rancher rancher-prime/rancher -n cattle-system --create-namespace \
    --set hostname=$CLUSTER_DOMAIN \
    --set bootstrapPassword=admin \
    --set ingress.tls.source=secret \
    --set ingress.tls.secretName=tls-rancher-ingress \
    --set privateCA=true
EOF

if [ $? -eq 0 ]; then
  echo "Rancher installed successfully." | tee -a "$LOG_FILE"
else
  echo "Error installing Rancher. Check $LOG_FILE for details." | tee -a "$LOG_FILE"
  exit 1
fi

# Stop the HTTP server
kill "$SERVER_PID"
echo "HTTP server stopped." | tee -a "$LOG_FILE"

# Optional: DNS configuration (example for AWS Route 53, client must provide credentials)
# Uncomment and adjust if you have DNS provider details
# echo "Configuring DNS (example for AWS Route 53)..." | tee -a "$LOG_FILE"
# AWS_ACCESS_KEY="YOUR_AWS_ACCESS_KEY"
# AWS_SECRET_KEY="YOUR_AWS_SECRET_KEY"
# for i in $(seq 0 $((NODE_COUNT - 1))); do
#   aws route53 change-resource-record-sets \
#     --hosted-zone-id YOUR_HOSTED_ZONE_ID \
#     --change-batch "{\"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"rancher0$((i + 1)).$DOMAIN\", \"Type\": \"A\", \"TTL\": 300, \"ResourceRecords\": [{\"Value\": \"${STATIC_IPS[$i]}\"}]}}]}" \
#     --region us-east-1 >> "$LOG_FILE" 2>&1
# done
# aws route53 change-resource-record-sets \
#   --hosted-zone-id YOUR_HOSTED_ZONE_ID \
#   --change-batch "{\"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {\"Name\": \"$CLUSTER_DOMAIN\", \"Type\": \"A\", \"TTL\": 300, \"ResourceRecords\": [{\"Value\": \"$VIP\"}]}}]}" \
#   --region us-east-1 >> "$LOG_FILE" 2>&1

echo "Deployment complete at $(date)!" | tee -a "$LOG_FILE"
echo "Verify the cluster:" | tee -a "$LOG_FILE"
echo "  ssh ubuntu@${STATIC_IPS[0]}" | tee -a "$LOG_FILE"
echo "  sudo kubectl get nodes" | tee -a "$LOG_FILE"
echo "Access Rancher at: https://$CLUSTER_DOMAIN" | tee -a "$LOG_FILE"
echo "Logs saved to $LOG_FILE" | tee -a "$LOG_FILE"
