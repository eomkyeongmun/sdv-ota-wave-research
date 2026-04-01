# =============================================================================
# 04-verify-comms.ps1
# Verify service-to-service communication in the ota-pipeline namespace.
# Fixed for Windows PowerShell Compatibility.
# =============================================================================
$ErrorActionPreference = "Continue"

$NAMESPACE = "ota-pipeline"
$PASS = 0
$FAIL = 0

# Helper: run curl inside a named pod via Python
function Invoke-PodCurl($PodName, $Url) {
    $py = @"
import urllib.request, sys
try:
    r = urllib.request.urlopen('$Url', timeout=5)
    print(r.read().decode())
except Exception as e:
    print('ERROR:', e, file=sys.stderr)
    sys.exit(1)
"@
    # Windows PowerShell에서는 따옴표 처리가 중요하므로 파이썬 스크립트를 전달할 때 주의
    kubectl exec -n $NAMESPACE $PodName -- python3 -c $py 2>$null
}

# Helper: get first pod name for a service label
function Get-Pod($Svc) {
    kubectl get pod -n $NAMESPACE -l "app=$Svc" -o jsonpath='{.items[0].metadata.name}'
}

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Week 1 Communication Verification (Fixed Version)"
Write-Host " Namespace: $NAMESPACE"
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$AUTH_POD     = Get-Pod "auth"
$CAMPAIGN_POD = Get-Pod "campaign"
$PACKAGE_POD  = Get-Pod "package"
$DEPLOY_POD   = Get-Pod "deploy"

Write-Host "Pods found:"
Write-Host "  auth     -> $AUTH_POD"
Write-Host "  campaign -> $CAMPAIGN_POD"
Write-Host "  package  -> $PACKAGE_POD"
Write-Host "  deploy   -> $DEPLOY_POD"
Write-Host ""

# ---- Test 1: Individual health checks ---------------------------------------
Write-Host "--- Test 1: Health checks (per service) ---"
foreach ($svc in @("auth","campaign","package","deploy")) {
    $pod    = Get-Pod $svc
    $result = Invoke-PodCurl $pod "http://localhost:8080/health"
    if ($result -match "ok") {
        Write-Host "  [PASS] $svc /health -> $result" -ForegroundColor Green
        $PASS++
    } else {
        Write-Host "  [FAIL] $svc /health -> $result" -ForegroundColor Red
        $FAIL++
    }
}
Write-Host ""

# ---- Test 2: Cross-service DNS resolution -----------------------------------
Write-Host "--- Test 2: Cross-service DNS resolution ---"
foreach ($target in @("auth","campaign","package","deploy")) {
    $result = Invoke-PodCurl $AUTH_POD "http://${target}:8080/health"
    if ($result -match "ok") {
        Write-Host "  [PASS] auth -> ${target}:8080/health" -ForegroundColor Green
        $PASS++
    } else {
        Write-Host "  [FAIL] auth -> ${target}:8080/health  ($result)" -ForegroundColor Red
        $FAIL++
    }
}
Write-Host ""

# ---- Test 3: Full pipeline chain --------------------------------------------
Write-Host "--- Test 3: Full pipeline chain  auth -> campaign -> package -> deploy ---"
$chain = Invoke-PodCurl $AUTH_POD "http://auth:8080/call"
if ($chain -match '"deploy"') {
    Write-Host "  Response: $chain"
    Write-Host "  [PASS] Full chain reached deploy" -ForegroundColor Green
    $PASS++
} else {
    Write-Host "  [FAIL] Chain did not reach deploy" -ForegroundColor Red
    $FAIL++
}
Write-Host ""

# ---- Test 4: /info endpoint -------------------------------------------------
Write-Host "--- Test 4: /info endpoint (env verification) ---"
foreach ($svc in @("auth","campaign","package","deploy")) {
    $pod  = Get-Pod $svc
    $info = Invoke-PodCurl $pod "http://localhost:8080/info"
    Write-Host "  ${svc}: $info"
}
Write-Host ""

# ---- Test 5: Envoy sidecar injection ----------------------------------------
Write-Host "--- Test 5: Envoy sidecar injection ---"
foreach ($svc in @("auth","campaign","package","deploy")) {
    $pod   = Get-Pod $svc
    # Windows 호환성을 위해 jsonpath에서 \n을 제거하고 공백으로 구분된 리스트를 가져옴
    $containerNames = kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.spec.containers[*].name}'
    $count = ($containerNames -split "\s+" | Where-Object { $_ -ne "" }).Count
    
    if ($count -ge 2) {
        Write-Host "  [PASS] $svc pod has $count containers (istio-proxy injected)" -ForegroundColor Green
        $PASS++
    } else {
        Write-Host "  [WARN] $svc pod has $count container(s) - sidecar may not be injected" -ForegroundColor Yellow
        $FAIL++
    }
}
Write-Host ""

# ---- Summary ----------------------------------------------------------------
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Results: PASS=$PASS  FAIL=$FAIL"
Write-Host "========================================================" -ForegroundColor Cyan
if ($FAIL -eq 0) {
    Write-Host " Week 1 environment is READY for Week 2 experiments." -ForegroundColor Green
} else {
    Write-Host " Fix the failing tests before proceeding to Week 2." -ForegroundColor Red
}