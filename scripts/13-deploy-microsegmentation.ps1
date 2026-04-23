<#
.SYNOPSIS
    Week 5 - Deploy Least-Privilege Microsegmentation
    ServiceAccount per service + STRICT mTLS + NetworkPolicy + AuthorizationPolicy
    + 자동 검증 (14-verify 호출)
#>

$ErrorActionPreference = "Continue"
$NS           = "ota-pipeline"
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$K8S_DIR      = Join-Path $PROJECT_ROOT "k8s"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 5 - Deploy Microsegmentation"         -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: ServiceAccounts
Write-Host "[1/6] Creating ServiceAccounts..."
kubectl apply -f "$K8S_DIR\serviceaccounts.yaml"
Write-Host ""

# Step 2: SA 지정 + rollout + 실제 SA 검증
Write-Host "[2/6] Setting ServiceAccounts on deployments..."
$saMap = [ordered]@{
    "auth"     = "auth-sa"
    "campaign" = "campaign-sa"
    "package"  = "package-sa"
    "deploy"   = "deploy-sa"
}
foreach ($svc in $saMap.Keys) {
    $sa = $saMap[$svc]
    kubectl set serviceaccount deployment $svc $sa -n $NS
    kubectl rollout restart deployment/$svc -n $NS
    Write-Host "  set $svc -> $sa (rollout restarted)"
}

Write-Host "  Waiting for rollouts..."
foreach ($svc in $saMap.Keys) {
    kubectl rollout status deployment/$svc -n $NS --timeout=120s
}

# SA 실제 적용 확인
Write-Host "  Verifying SA assignment on pods..."
$allOk = $true
foreach ($svc in $saMap.Keys) {
    $expected = $saMap[$svc]
    $actual   = kubectl get pod -n $NS -l "app=$svc" `
                    -o jsonpath='{.items[0].spec.serviceAccountName}' 2>$null
    if ($actual -eq $expected) {
        Write-Host "  [OK] $svc pod SA = $actual" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $svc pod SA = '$actual' (expected '$expected')" -ForegroundColor Red
        $allOk = $false
    }
}
if (-not $allOk) {
    Write-Host "  SA verification failed. Aborting." -ForegroundColor Red
    exit 1
}
Write-Host ""

# Step 3: PeerAuthentication STRICT
Write-Host "[3/6] Upgrading PeerAuthentication to STRICT mTLS..."
kubectl apply -f "$K8S_DIR\peer-auth-strict.yaml"
Write-Host ""

# Step 4: NetworkPolicy chain
Write-Host "[4/6] Applying NetworkPolicy chain..."
kubectl apply -f "$K8S_DIR\networkpolicy-chain.yaml"
Write-Host ""

# Step 5: AuthorizationPolicy chain
Write-Host "[5/6] Applying AuthorizationPolicy chain..."
foreach ($svc in $saMap.Keys) {
    kubectl delete authorizationpolicy "hstp-deny-$svc" -n $NS 2>$null | Out-Null
}
kubectl apply -f "$K8S_DIR\authpolicy-chain.yaml"

# Envoy cert + policy 동기화 대기 (60s — SA 변경 후 istiod 재발급 필요)
Write-Host "  Waiting 60s for Envoy cert re-issue and policy propagation..."
$total = 60
for ($i = 10; $i -le $total; $i += 10) {
    Start-Sleep -Seconds 10
    Write-Host "  [$i/$total s]"
}
Write-Host ""

# Step 6: 체인 빠른 확인
Write-Host "[6/6] Quick chain sanity check..."
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run load-gen -n $NS --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $s = kubectl get pod load-gen -n $NS --no-headers 2>$null
} while ($s -notmatch "Running" -and $waited -lt 60)

$raw   = kubectl exec load-gen -n $NS -- `
    curl -s -o /tmp/r.txt -w "%{http_code}" --connect-timeout 3 --max-time 8 `
    http://auth:8080/call 2>$null
$code  = ($raw | Select-Object -Last 1).Trim()
$body  = kubectl exec load-gen -n $NS -- cat /tmp/r.txt 2>$null
$depth = 0
foreach ($s in @("auth","campaign","package","deploy")) { if ($body -match $s) { $depth++ } }

$chainColor = if ($code -eq "200" -and $depth -eq 4) { "Green" } else { "Red" }
Write-Host "  Chain: HTTP $code  depth=$depth/4" -ForegroundColor $chainColor

if ($code -ne "200" -or $depth -lt 4) {
    Write-Host "  Chain not fully working. Check Envoy logs:" -ForegroundColor Yellow
    Write-Host "  kubectl logs -n ota-pipeline -l app=campaign -c istio-proxy --tail=20"
} else {
    Write-Host "  Chain OK. Running full verification..." -ForegroundColor Green
    kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
    & "$PSScriptRoot\14-verify-microsegmentation.ps1"
}

kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
