# =============================================================================
# 03-deploy-services.ps1
# Deploy the four OTA pipeline dummy services into the ota-pipeline namespace.
# Service chain: auth -> campaign -> package -> deploy
# Usage: .\scripts\03-deploy-services.ps1
# =============================================================================
$ErrorActionPreference = "Continue"

$NAMESPACE    = "ota-pipeline"
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$K8S_DIR      = Join-Path $PROJECT_ROOT "k8s"

Write-Host "=== [03] Deploying OTA pipeline services ===" -ForegroundColor Cyan

# ---- Namespace + sidecar injection label ------------------------------------
Write-Host "Applying namespace..."
kubectl apply -f "$K8S_DIR/namespace.yaml"

# ---- Shared ConfigMap -------------------------------------------------------
Write-Host "Applying ConfigMap (app.py)..."
kubectl apply -f "$K8S_DIR/configmap.yaml"

# ---- Four dummy services ----------------------------------------------------
foreach ($svc in @("auth","campaign","package","deploy")) {
    Write-Host "Applying $svc..."
    kubectl apply -f "$K8S_DIR/$svc.yaml"
}

# ---- Istio PeerAuthentication -----------------------------------------------
Write-Host "Applying PeerAuthentication (PERMISSIVE)..."
kubectl apply -f "$K8S_DIR/peer-auth.yaml"

# ---- Wait for all pods ------------------------------------------------------
Write-Host ""
Write-Host "=== Waiting for all pods to be Running/Ready ===" -ForegroundColor Cyan
kubectl wait --for=condition=Ready pod `
    -l "app in (auth,campaign,package,deploy)" `
    -n $NAMESPACE `
    --timeout=120s

Write-Host ""
Write-Host "=== Pod status ===" -ForegroundColor Cyan
kubectl get pods -n $NAMESPACE -o wide

Write-Host ""
Write-Host "=== Services ===" -ForegroundColor Cyan
kubectl get svc -n $NAMESPACE

Write-Host ""
Write-Host "=== [03] DONE ===" -ForegroundColor Green
Write-Host "Next step: .\scripts\04-verify-comms.ps1"
