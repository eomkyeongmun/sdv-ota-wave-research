#!/usr/bin/env bash
# =============================================================================
# 01-setup-kind.sh
# Create a kind (Kubernetes-in-Docker) cluster for OTA research.
#
# Prerequisites:
#   - Docker Desktop running
#   - kind installed  (winget install Kubernetes.kind  OR  choco install kind)
#   - kubectl installed
#
# Usage:
#   bash scripts/01-setup-kind.sh
# =============================================================================
set -euo pipefail

CLUSTER_NAME="ota-research"
K8S_VERSION="v1.29.2"

echo "=== [01] Setting up kind cluster: ${CLUSTER_NAME} ==="

# Delete existing cluster if it exists (idempotent re-run)
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
  echo "To recreate:  kind delete cluster --name ${CLUSTER_NAME}"
else
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "kindest/node:${K8S_VERSION}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    # Extra port mappings are useful if you later expose an Ingress/Gateway.
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443
        hostPort: 8443
        protocol: TCP
EOF
  echo "Cluster created."
fi

echo ""
echo "=== Verifying cluster nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== [01] DONE ==="
echo "Next step: bash scripts/02-install-istio.sh"
