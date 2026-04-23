<#
.SYNOPSIS
    Week 4 - Deploy Hierarchical Safe Transition Protocol
    OTAWave CRD + RBAC + Controller 를 클러스터에 배포한다.
#>

$ErrorActionPreference = "Continue"
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$K8S_DIR      = Join-Path $PROJECT_ROOT "k8s"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 4 - Deploy HSTP"                      -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: OTAWave CRD
Write-Host "[1/4] Applying OTAWave CRD..."
kubectl apply -f "$K8S_DIR\otawave-crd.yaml"
Start-Sleep -Seconds 3

# CRD 등록 확인
$crd = kubectl get crd otawaves.ota.research --no-headers 2>$null
if ($crd) {
    Write-Host "  CRD registered: otawaves.ota.research" -ForegroundColor Green
} else {
    Write-Host "  CRD registration failed" -ForegroundColor Red
    exit 1
}

# Step 2: RBAC
Write-Host "`n[2/4] Applying RBAC (ServiceAccount + ClusterRole)..."
kubectl apply -f "$K8S_DIR\otawave-rbac.yaml"

# Step 3: Controller (ConfigMap + Deployment)
Write-Host "`n[3/4] Deploying HSTP Controller..."
kubectl apply -f "$K8S_DIR\otawave-controller.yaml"

# Step 4: Controller 준비 대기
Write-Host "`n[4/4] Waiting for controller to be ready..."
Write-Host "  (pip install kubernetes takes ~30s on first start)"
$waited = 0
do {
    Start-Sleep -Seconds 5
    $waited += 5
    $status = kubectl get pod -n ota-pipeline -l app=hstp-controller --no-headers 2>$null
    Write-Host "  [$waited s] $status"
} while ($status -notmatch "Running" -and $waited -lt 120)

if ($status -match "Running") {
    Write-Host "  Controller is Running." -ForegroundColor Green
} else {
    Write-Host "  Controller not ready yet - check logs:" -ForegroundColor Yellow
    Write-Host "  kubectl logs -n ota-pipeline -l app=hstp-controller"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  HSTP Deployed"                             -ForegroundColor Green
Write-Host ""
Write-Host "  CRD:        otawaves.ota.research"
Write-Host "  Controller: hstp-controller (ota-pipeline)"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  .\11-hstp-safe-deactivation.ps1   <- safe deact test"
Write-Host "  .\12-verify-hstp.ps1              <- lateral movement blocked?"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
