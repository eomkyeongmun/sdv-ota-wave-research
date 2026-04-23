<#
.SYNOPSIS
    Week 3 - Lateral Movement Baseline Test
    NetworkPolicy / AuthorizationPolicy 없는 상태에서
    공격자 pod가 내부 서비스에 직접 접근 가능한지 측정한다.

    Threat model: 공격자가 임의 pod 안에 code execution 획득.
    K8s admin / host 권한 없음.

.DESCRIPTION
    1. attacker pod 를 ota-pipeline 네임스페이스에 배포
    2. 모든 서비스가 정상 실행 중인 상태에서 직접 접근 시도
    3. 각 서비스의 /call /health /info 엔드포인트에 직접 curl
    4. 결과를 CSV 로 저장

.EXAMPLE
    .\08-lateral-movement.ps1
#>

$ErrorActionPreference = "Continue"

$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$CSV_FILE  = Join-Path $LOG_DIR "lateral-movement-baseline-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

$SERVICES   = @("auth", "campaign", "package", "deploy")
$ENDPOINTS  = @("/health", "/info", "/call")

# CSV 초기화
$header = "experiment_id,attacker_pod,target_service,endpoint,elapsed_sec,http_status,response_time_ms,accessible,notes"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

$experimentId = "LATERAL-BASELINE-$TIMESTAMP"
$startTime    = Get-Date

function Write-Csv {
    param([string]$AttackerPod, [string]$Target, [string]$Endpoint,
          [string]$HttpCode, [int]$RespMs, [string]$Accessible, [string]$Notes = "")
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    $row = "$experimentId,$AttackerPod,$Target,$Endpoint,$elapsed,$HttpCode,$RespMs,$Accessible,$Notes"
    Add-Content -Path $CSV_FILE -Value $row -Encoding UTF8
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 3 - Lateral Movement Baseline Test"   -ForegroundColor Cyan
Write-Host "  Threat: code exec in pod, no admin priv"   -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: 모든 서비스 실행 확인
Write-Host "[SETUP] Ensuring all services are running..."
foreach ($svc in $SERVICES) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in $SERVICES) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}
Write-Host "[SETUP] All services ready.`n"

# Step 2: 공격자 pod 배포 (같은 네임스페이스 - 가장 현실적인 침해 시나리오)
Write-Host "[ATTACKER] Deploying attacker pod in ota-pipeline namespace..."
kubectl delete pod attacker -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run attacker -n $NS --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null

$waited = 0
do {
    Start-Sleep -Seconds 3
    $waited += 3
    $status = kubectl get pod attacker -n $NS --no-headers 2>$null
} while ($status -notmatch "Running" -and $waited -lt 60)
Write-Host "[ATTACKER] Attacker pod ready ($waited s).`n"

# Step 3: 각 서비스에 직접 접근 시도
Write-Host "[TEST] Attempting direct access to all internal services..." -ForegroundColor Yellow
Write-Host "       (simulating attacker with code exec in 'attacker' pod)`n"

foreach ($target in $SERVICES) {
    Write-Host "  Target: $target" -ForegroundColor Magenta
    foreach ($ep in $ENDPOINTS) {
        $t0 = Get-Date
        $raw = kubectl exec attacker -n $NS -- `
            curl -s -o /tmp/r.txt -w "%{http_code}" `
            --connect-timeout 3 --max-time 8 `
            "http://${target}:8080${ep}" 2>$null
        $httpCode = ($raw | Select-Object -Last 1).Trim()
        $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds
        $body     = kubectl exec attacker -n $NS -- cat /tmp/r.txt 2>$null

        $accessible = if ($httpCode -match "^2") { "YES" } else { "NO" }
        $color      = if ($accessible -eq "YES") { "Red" } else { "Green" }

        Write-Host ("    {0,-8} {1,-10} -> HTTP {2,-4} ({3}ms) [{4}]" -f `
            $target, $ep, $httpCode, $respMs, $accessible) -ForegroundColor $color

        Write-Csv -AttackerPod "attacker" -Target $target -Endpoint $ep `
                  -HttpCode $httpCode -RespMs $respMs -Accessible $accessible
    }
    Write-Host ""
}

# Step 4: 다른 네임스페이스에서도 시도 (default namespace)
Write-Host "[TEST] Attempting cross-namespace access from default namespace..." -ForegroundColor Yellow
kubectl delete pod attacker-ext -n default --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run attacker-ext -n default --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null

$waited = 0
do {
    Start-Sleep -Seconds 3
    $waited += 3
    $status = kubectl get pod attacker-ext -n default --no-headers 2>$null
} while ($status -notmatch "Running" -and $waited -lt 60)

Write-Host ""
foreach ($target in $SERVICES) {
    $t0 = Get-Date
    $raw = kubectl exec attacker-ext -n default -- `
        curl -s -o /tmp/r.txt -w "%{http_code}" `
        --connect-timeout 3 --max-time 8 `
        "http://${target}.${NS}.svc.cluster.local:8080/health" 2>$null
    $httpCode = ($raw | Select-Object -Last 1).Trim()
    $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds

    $accessible = if ($httpCode -match "^2") { "YES" } else { "NO" }
    $color      = if ($accessible -eq "YES") { "Red" } else { "Green" }

    Write-Host ("  [cross-ns] {0,-10} /health -> HTTP {1,-4} ({2}ms) [{3}]" -f `
        $target, $httpCode, $respMs, $accessible) -ForegroundColor $color

    Write-Csv -AttackerPod "attacker-ext(default-ns)" -Target $target -Endpoint "/health" `
              -HttpCode $httpCode -RespMs $respMs -Accessible $accessible -Notes "cross-namespace"
}

# Cleanup
Write-Host "`n[CLEANUP] Removing attacker pods..."
kubectl delete pod attacker     -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker-ext -n default  --grace-period=0 --force 2>$null | Out-Null

# 결과 요약
$rows        = (Get-Content $CSV_FILE | Measure-Object -Line).Lines - 1
$allRows     = Get-Content $CSV_FILE | Select-Object -Skip 1
$accessible  = ($allRows | Where-Object { $_ -match ",YES," }).Count
$blocked     = ($allRows | Where-Object { $_ -match ",NO," }).Count

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: Lateral Movement Baseline"         -ForegroundColor Green
Write-Host "  Total tests   : $rows"
Write-Host "  ACCESSIBLE    : $accessible" -ForegroundColor Red
Write-Host "  BLOCKED       : $blocked"   -ForegroundColor Green
Write-Host "  Output CSV    : $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
if ($accessible -gt 0) {
    Write-Host "  !! $accessible services accessible without policy !!" -ForegroundColor Red
    Write-Host "  -> Run 09-lateral-movement-during-transition.ps1"     -ForegroundColor Yellow
    Write-Host "     to measure the attack window during D2 transition." -ForegroundColor Yellow
}
Write-Host ""
