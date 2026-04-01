#!/usr/bin/env bash
# =============================================================================
# 03-deploy-services.sh
# Deploy the four OTA pipeline dummy services into the ota-pipeline namespace.
#
# Service chain:  auth -> campaign -> package -> deploy
#
# Prerequisites:
#   - Istio installed  (run 02-install-istio.sh first)
#
# Usage:
#   bash scripts/03-deploy-services.sh
# =============================================================================
set -euo pipefail

NAMESPACE="ota-pipeline"

echo "=== [03] Deploying OTA pipeline services ==="

# ---- Namespace + sidecar injection label ----------------------------------
echo "Applying namespace..."
kubectl apply -f k8s/namespace.yaml

# ---- Shared ConfigMap (Python app code) -----------------------------------
echo "Applying ConfigMap (app.py)..."
kubectl apply -f k8s/configmap.yaml

# ---- Four dummy services --------------------------------------------------
for svc in auth campaign package deploy; do
  echo "Applying ${svc}..."
  kubectl apply -f "k8s/${svc}.yaml"
done

# ---- Istio PeerAuthentication (PERMISSIVE for Week 1) ---------------------
echo "Applying PeerAuthentication (PERMISSIVE)..."
kubectl apply -f k8s/peer-auth.yaml

# ---- Wait for all pods to be ready ----------------------------------------
echo ""
echo "=== Waiting for all pods to be Running/Ready ==="
kubectl wait --for=condition=Ready pod \
  -l 'app in (auth,campaign,package,deploy)' \
  -n "${NAMESPACE}" \
  --timeout=120s

echo ""
echo "=== Pod status ==="
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo "=== Services ==="
kubectl get svc -n "${NAMESPACE}"

echo ""
echo "=== [03] DONE ==="
echo "Next step: bash scripts/04-verify-comms.sh"
