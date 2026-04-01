# =============================================================================
# 02-install-istio.ps1
# Download istioctl and install Istio (default profile) into the kind cluster.
# Usage: .\scripts\02-install-istio.ps1
# =============================================================================
$ErrorActionPreference = "Continue"

$ISTIO_VERSION = "1.21.2"
$ISTIO_DIR     = "istio-$ISTIO_VERSION"
$ISTIOCTL      = ".\istioctl.exe"

Write-Host "=== [02] Installing Istio $ISTIO_VERSION ===" -ForegroundColor Cyan

# ---- Download istioctl if not already present -------------------------------
if (-not (Test-Path $ISTIOCTL)) {
    Write-Host "Downloading istioctl $ISTIO_VERSION..."
    $url  = "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istioctl-$ISTIO_VERSION-win.zip"
    $zip  = "$env:TEMP\istioctl.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath "." -Force
    Remove-Item $zip
    Write-Host "istioctl.exe saved to $ISTIOCTL"
} else {
    Write-Host "istioctl.exe already present — skipping download."
}

Write-Host "istioctl version: $(& $ISTIOCTL version --remote=false)"

# ---- Pre-flight check -------------------------------------------------------
Write-Host ""
Write-Host "=== Pre-flight check ===" -ForegroundColor Cyan
& $ISTIOCTL x precheck

# ---- Install Istio (default profile) ----------------------------------------
Write-Host ""
Write-Host "=== Installing Istio with 'default' profile ===" -ForegroundColor Cyan
& $ISTIOCTL install --set profile=default -y

# ---- Wait for istiod ---------------------------------------------------------
Write-Host ""
Write-Host "=== Waiting for istiod to be ready ===" -ForegroundColor Cyan
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

Write-Host ""
Write-Host "=== Istio components ===" -ForegroundColor Cyan
kubectl get pods -n istio-system

Write-Host ""
Write-Host "=== [02] DONE ===" -ForegroundColor Green
Write-Host "Next step: .\scripts\03-deploy-services.ps1"
