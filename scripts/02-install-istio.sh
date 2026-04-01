#!/usr/bin/env bash
# =============================================================================
# 02-install-istio.sh
# Download istioctl and install Istio (default profile) into the kind cluster.
#
# Prerequisites:
#   - kind cluster running  (run 01-setup-kind.sh first)
#   - curl available
#
# Usage:
#   bash scripts/02-install-istio.sh
# =============================================================================
set -euo pipefail

ISTIO_VERSION="1.21.2"
ISTIO_DIR="istio-${ISTIO_VERSION}"

echo "=== [02] Installing Istio ${ISTIO_VERSION} ==="

# ---- Download istioctl if not already present ----------------------------
if [ ! -f "./${ISTIO_DIR}/bin/istioctl" ] && [ ! -f "./istioctl" ]; then
  echo "Downloading Istio ${ISTIO_VERSION}..."
  curl -sL "https://istio.io/downloadIstio" | ISTIO_VERSION="${ISTIO_VERSION}" sh -
  cp "./${ISTIO_DIR}/bin/istioctl" ./istioctl
  echo "istioctl saved to ./istioctl"
else
  echo "istioctl already present — skipping download."
fi

ISTIOCTL="./istioctl"
if [ -f "./${ISTIO_DIR}/bin/istioctl" ]; then
  ISTIOCTL="./${ISTIO_DIR}/bin/istioctl"
fi

echo "istioctl version: $(${ISTIOCTL} version --remote=false)"

# ---- Pre-check ------------------------------------------------------------
echo ""
echo "=== Pre-flight check ==="
${ISTIOCTL} x precheck

# ---- Install Istio (default profile: istiod + ingress-gateway) -----------
echo ""
echo "=== Installing Istio with 'default' profile ==="
${ISTIOCTL} install --set profile=default -y

# ---- Wait for istiod to be ready -----------------------------------------
echo ""
echo "=== Waiting for istiod to be ready ==="
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

echo ""
echo "=== Istio components ==="
kubectl get pods -n istio-system

echo ""
echo "=== [02] DONE ==="
echo "Next step: bash scripts/03-deploy-services.sh"
