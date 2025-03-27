#!/bin/bash
set -e
LOG_FILE="deploy.log"
NAMESPACE="default"
RELEASE_NAME="rke2-ha-cluster"
VIP="10.31.42.100"  # From values.yaml
CLUSTER_DOMAIN="rancher-cluster.example.com"  # From values.yaml

echo "Deployment started at $(date)" > "$LOG_FILE"

# Check prerequisites
if ! command -v helm >/dev/null 2>&1; then
  echo "Error: Helm is not installed. Please install it first." | tee -a "$LOG_FILE"
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is not installed. Please install it first." | tee -a "$LOG_FILE"
  exit 1
fi
if ! kubectl config current-context >/dev/null 2>&1; then
  echo "Error: No valid kubectl context found. Ensure you're connected to your Harvester cluster." | tee -a "$LOG_FILE"
  exit 1
fi
for CERT in abc.cert abc.key cacerts.pem; do
  if [ ! -f "$CERT" ]; then
    echo "Error: Certificate file $CERT not found in current directory." | tee -a "$LOG_FILE"
    exit 1
  fi
done

# Install Helm chart
echo "Installing Helm chart $RELEASE_NAME in namespace $NAMESPACE..." | tee -a "$LOG_FILE"
helm upgrade -i "$RELEASE_NAME" . -n "$NAMESPACE" --create-namespace >> "$LOG_FILE" 2>&1

# Wait for VMs to be running
echo "Waiting for VMs to be ready..." | tee -a "$LOG_FILE"
NODE_COUNT=$(grep "nodeCount:" values.yaml | awk '{print $2}')
for i in $(seq 1 "$NODE_COUNT"); do
  until kubectl get vm "rke2-node-$i-$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' | grep -q "Running"; do
    echo "Waiting for rke2-node-$i-$RELEASE_NAME to be Running..." | tee -a "$LOG_FILE"
    sleep 10
  done
  echo "rke2-node-$i-$RELEASE_NAME is Running" | tee -a "$LOG_FILE"
done

# Get the first node's IP
FIRST_NODE_IP=$(kubectl get vmi "rke2-node-1-$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}')
if [ -z "$FIRST_NODE_IP" ]; then
  echo "Error: Could not retrieve IP for first node." | tee -a "$LOG_FILE"
  exit 1
fi
echo "First node IP: $FIRST_NODE_IP" | tee -a "$LOG_FILE"

# Wait for RKE2 cluster to be ready
echo "Waiting for RKE2 cluster to be ready on $FIRST_NODE_IP..." | tee -a "$LOG_FILE"
until ssh -o StrictHostKeyChecking=no ubuntu@"$FIRST_NODE_IP" "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; kubectl get nodes | grep -q Ready" >/dev/null 2>&1; do
  echo "Waiting for RKE2 cluster to report all nodes Ready..." | tee -a "$LOG_FILE"
  sleep 15
done
echo "RKE2 cluster is ready!" | tee -a "$LOG_FILE"

# Verify Kube-VIP
echo "Verifying Kube-VIP on $FIRST_NODE_IP..." | tee -a "$LOG_FILE"
if ssh -o StrictHostKeyChecking=no ubuntu@"$FIRST_NODE_IP" "sudo ip a | grep -q $VIP" >/dev/null 2>&1; then
  echo "Kube-VIP is active on $VIP" | tee -a "$LOG_FILE"
else
  echo "Error: Kube-VIP ($VIP) not found on $FIRST_NODE_IP" | tee -a "$LOG_FILE"
  exit 1
fi

# Install Rancher
echo "Installing Rancher on $FIRST_NODE_IP..." | tee -a "$LOG_FILE"
scp -o StrictHostKeyChecking=no abc.cert abc.key cacerts.pem ubuntu@"$FIRST_NODE_IP":/home/ubuntu/ >> "$LOG_FILE" 2>&1
ssh -o StrictHostKeyChecking=no ubuntu@"$FIRST_NODE_IP" << EOF >> "$LOG_FILE" 2>&1
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  kubectl create ns cattle-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n cattle-system create secret tls tls-rancher-ingress --cert=/home/ubuntu/abc.cert --key=/home/ubuntu/abc.key --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n cattle-system create secret generic tls-ca --from-file=/home/ubuntu/cacerts.pem --dry-run=client -o yaml | kubectl apply -f -
  helm repo add rancher-prime https://charts.rancher.com/server-charts/prime
  helm repo update
  helm upgrade -i rancher rancher-prime/rancher -n cattle-system --create-namespace \
    --set hostname=$CLUSTER_DOMAIN \
    --set bootstrapPassword=admin \
    --set ingress.tls.source=secret \
    --set ingress.tls.secretName=tls-rancher-ingress \
    --set privateCA=true \
    --set replicas=3
EOF

# Wait for Rancher to be ready
echo "Waiting for Rancher to be ready..." | tee -a "$LOG_FILE"
until ssh -o StrictHostKeyChecking=no ubuntu@"$FIRST_NODE_IP" "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; kubectl -n cattle-system get deploy rancher -o jsonpath='{.status.readyReplicas}' | grep -q 3" >/dev/null 2>&1; do
  echo "Waiting for Rancher deployment to have 3 ready replicas..." | tee -a "$LOG_FILE"
  sleep 15
done
echo "Rancher is ready!" | tee -a "$LOG_FILE"

# Update local /etc/hosts
echo "Updating /etc/hosts with $VIP $CLUSTER_DOMAIN..." | tee -a "$LOG_FILE"
if ! grep -q "$VIP $CLUSTER_DOMAIN" /etc/hosts; then
  echo "$VIP $CLUSTER_DOMAIN" | sudo tee -a /etc/hosts
fi

echo "Deployment complete at $(date)!" | tee -a "$LOG_FILE"
echo "Access Rancher at: https://$CLUSTER_DOMAIN" | tee -a "$LOG_FILE"
echo "Verify cluster: ssh ubuntu@$FIRST_NODE_IP 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; kubectl get nodes'" | tee -a "$LOG_FILE"
