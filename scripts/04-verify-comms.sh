#!/usr/bin/env bash
# =============================================================================
# 04-verify-comms.sh
# Verify service-to-service communication in the ota-pipeline namespace.
#
# Tests performed:
#   1. Health check for each service (individual pod)
#   2. Pipeline chain call: auth -> campaign -> package -> deploy
#   3. Cross-service direct call from auth pod to each peer
#   4. Print Envoy sidecar status (confirms Istio injection)
#
# Usage:
#   bash scripts/04-verify-comms.sh
#   bash scripts/04-verify-comms.sh 2>&1 | tee logs/week1-verify.log
# =============================================================================
set -euo pipefail

NAMESPACE="ota-pipeline"
PASS=0
FAIL=0

# Helper: run curl inside a named pod, return HTTP body
pod_curl() {
  local pod_name="$1"
  local url="$2"
  kubectl exec -n "${NAMESPACE}" "${pod_name}" \
    -- python3 -c "
import urllib.request, sys
try:
    r = urllib.request.urlopen('${url}', timeout=5)
    print(r.read().decode())
except Exception as e:
    print('ERROR:', e, file=sys.stderr)
    sys.exit(1)
"
}

# Get one pod name per service
get_pod() {
  kubectl get pod -n "${NAMESPACE}" -l "app=$1" \
    -o jsonpath='{.items[0].metadata.name}'
}

echo "========================================================"
echo " Week 1 Communication Verification"
echo " Namespace: ${NAMESPACE}"
echo "========================================================"
echo ""

AUTH_POD=$(get_pod auth)
CAMPAIGN_POD=$(get_pod campaign)
PACKAGE_POD=$(get_pod package)
DEPLOY_POD=$(get_pod deploy)

echo "Pods found:"
echo "  auth     -> ${AUTH_POD}"
echo "  campaign -> ${CAMPAIGN_POD}"
echo "  package  -> ${PACKAGE_POD}"
echo "  deploy   -> ${DEPLOY_POD}"
echo ""

# ---- Test 1: Individual health checks ------------------------------------
echo "--- Test 1: Health checks (per service) ---"
for svc in auth campaign package deploy; do
  pod=$(get_pod "${svc}")
  result=$(pod_curl "${pod}" "http://localhost:8080/health" 2>&1)
  if echo "${result}" | grep -q "ok"; then
    echo "  [PASS] ${svc} /health -> ${result}"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] ${svc} /health -> ${result}"
    FAIL=$((FAIL+1))
  fi
done
echo ""

# ---- Test 2: Cross-service calls via Kubernetes DNS ----------------------
echo "--- Test 2: Cross-service DNS resolution ---"
# Call each service FROM auth pod
for target in auth campaign package deploy; do
  result=$(pod_curl "${AUTH_POD}" "http://${target}:8080/health" 2>&1)
  if echo "${result}" | grep -q "ok"; then
    echo "  [PASS] auth -> ${target}:8080/health"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] auth -> ${target}:8080/health  (${result})"
    FAIL=$((FAIL+1))
  fi
done
echo ""

# ---- Test 3: Full pipeline chain call ------------------------------------
echo "--- Test 3: Full pipeline chain  auth -> campaign -> package -> deploy ---"
chain_result=$(pod_curl "${AUTH_POD}" "http://auth:8080/call" 2>&1)
echo "  Response: ${chain_result}"
if echo "${chain_result}" | grep -q '"deploy"'; then
  echo "  [PASS] Full chain reached deploy"
  PASS=$((PASS+1))
else
  echo "  [FAIL] Chain did not reach deploy"
  FAIL=$((FAIL+1))
fi
echo ""

# ---- Test 4: Info endpoint -----------------------------------------------
echo "--- Test 4: /info endpoint (env verification) ---"
for svc in auth campaign package deploy; do
  pod=$(get_pod "${svc}")
  info=$(pod_curl "${pod}" "http://localhost:8080/info" 2>&1)
  echo "  ${svc}: ${info}"
done
echo ""

# ---- Test 5: Envoy sidecar injection check --------------------------------
echo "--- Test 5: Envoy sidecar injection ---"
for svc in auth campaign package deploy; do
  pod=$(get_pod "${svc}")
  container_count=$(kubectl get pod -n "${NAMESPACE}" "${pod}" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -c '.')
  if [ "${container_count}" -ge 2 ]; then
    echo "  [PASS] ${svc} pod has ${container_count} containers (istio-proxy injected)"
    PASS=$((PASS+1))
  else
    echo "  [WARN] ${svc} pod has ${container_count} container(s) — sidecar may not be injected"
    FAIL=$((FAIL+1))
  fi
done
echo ""

# ---- Summary -------------------------------------------------------------
echo "========================================================"
echo " Results: PASS=${PASS}  FAIL=${FAIL}"
echo "========================================================"
if [ "${FAIL}" -eq 0 ]; then
  echo " Week 1 environment is READY for Week 2 experiments."
else
  echo " Fix the failing tests before proceeding to Week 2."
fi
