<#
.SYNOPSIS
    Week 4 - HSTP Safe Deactivation Test
    OTAWave CR을 생성해 HSTP 컨트롤러가 안전한 순서로 서비스를
    deactivation 하는지 검증한다.

    동시에 load-gen이 요청을 계속 보내 성공/실패율을 측정한다.
    (Week 2 D2와 비교: HSTP 적용 전후 security hole 차이)

.PARAMETER DrainSeconds
    각 서비스 제거 전 드레인 시간 (기본값: 10초)

.EXAMPLE
    .\11-hstp-safe-deactivation.ps1
    .\11-hstp-safe-deactivation.ps1 -DrainSeconds 15
#>
param([int]$DrainSeconds = 10)

$ErrorActionPreference = "Continue"
$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$CSV_FILE  = Join-Path $LOG_DIR "hstp-deactivation-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

$header = "experiment_id,phase,step,elapsed_sec,http_status,response_time_ms,pipeline_depth,wave_phase,notes"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

$experimentId = "HSTP-DEACT-$TIMESTAMP"
$startTime    = $null

function Write-Csv {
    param([string]$Phase, [string]$Step,
          [string]$HttpCode, [int]$RespMs, [int]$Depth,
          [string]$WavePhase, [string]$Notes = "")
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    Add-Content -Path $CSV_FILE -Value "$experimentId,$Phase,$Step,$elapsed,$HttpCode,$RespMs,$Depth,$WavePhase,$Notes" -Encoding UTF8
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 4 - HSTP Safe Deactivation Test"      -ForegroundColor Cyan
Write-Host "  Drain: ${DrainSeconds}s per service"        -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: 모든 서비스 실행
Write-Host "[SETUP] Ensuring all services are running..."
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}

# 기존 deny policy 정리
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl delete authorizationpolicy "hstp-deny-$svc" -n $NS 2>$null | Out-Null
}
Write-Host "[SETUP] All services ready, deny policies cleared.`n"

# Step 2: load-gen 배포 (요청 측정용)
Write-Host "[MEASURE] Deploying load-gen pod..."
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run load-gen -n $NS --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $s = kubectl get pod load-gen -n $NS --no-headers 2>$null
} while ($s -notmatch "Running" -and $waited -lt 60)
Write-Host "[MEASURE] load-gen ready.`n"

$startTime = Get-Date

# Step 3: OTAWave CR 생성 (HSTP D1 - 안전한 drain 순서)
$waveName = "hstp-deact-$TIMESTAMP"

$waveYaml = @"
apiVersion: ota.research/v1
kind: OTAWave
metadata:
  name: $waveName
  namespace: $NS
spec:
  action: deactivate
  order:
    - deploy
    - package
    - campaign
    - auth
  drainSeconds: $DrainSeconds
"@

Write-Host "[HSTP] Submitting OTAWave CR '$waveName' (safe deactivation order)..."
$waveYaml | kubectl apply -f - 2>&1 | Out-Null
Write-Host "[HSTP] OTAWave CR submitted. Controller will enforce safe order.`n"

# Step 4: 컨트롤러가 실행하는 동안 요청 측정
Write-Host "[MEASURE] Measuring requests while HSTP controller runs..."
$completed = $false
$count = 0
$maxWait = 300  # 5분 타임아웃

while (-not $completed -and ((Get-Date) - $startTime).TotalSeconds -lt $maxWait) {
    # 파이프라인 요청
    $t0 = Get-Date
    $raw = kubectl exec load-gen -n $NS -- `
        curl -s -o /tmp/r.txt -w "%{http_code}" `
        --connect-timeout 2 --max-time 5 `
        http://auth:8080/call 2>$null
    $httpCode = ($raw | Select-Object -Last 1).Trim()
    $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds
    $body     = kubectl exec load-gen -n $NS -- cat /tmp/r.txt 2>$null
    $depth    = 0
    foreach ($s in @("auth","campaign","package","deploy")) {
        if ($body -match $s) { $depth++ }
    }

    # OTAWave 상태 확인
    $waveStatus = kubectl get otawave $waveName -n $NS -o jsonpath='{.status.phase}' 2>$null
    $waveStep   = kubectl get otawave $waveName -n $NS -o jsonpath='{.status.currentStep}' 2>$null

    Write-Csv -Phase "transition" -Step "s$waveStep" `
              -HttpCode $httpCode -RespMs $respMs -Depth $depth `
              -WavePhase $waveStatus

    if ($count % 5 -eq 0) {
        Write-Host ("  [{0,5:f0}s] HTTP {1,-4} depth={2} wave={3}/step={4}" -f `
            ((Get-Date)-$startTime).TotalSeconds, $httpCode, $depth, $waveStatus, $waveStep)
    }
    $count++

    if ($waveStatus -eq "Completed" -or $waveStatus -eq "Failed") {
        $completed = $true
    }
    Start-Sleep -Seconds 2
}

# Step 5: 최종 상태
$finalPhase   = kubectl get otawave $waveName -n $NS -o jsonpath='{.status.phase}' 2>$null
$finalMessage = kubectl get otawave hstp-deact-test -n $NS -o jsonpath='{.status.message}' 2>$null
Write-Host "`n[HSTP] Wave final status: $finalPhase — $finalMessage"

# Step 6: HSTP 적용 후 lateral movement 시도 (attacker pod)
Write-Host "`n[VERIFY] Testing lateral movement AFTER HSTP deactivation..."
kubectl delete pod attacker -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run attacker -n $NS --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $s = kubectl get pod attacker -n $NS --no-headers 2>$null
} while ($s -notmatch "Running" -and $waited -lt 60)

foreach ($target in @("deploy","package","campaign","auth")) {
    $raw = kubectl exec attacker -n $NS -- `
        curl -s -o /dev/null -w "%{http_code}" `
        --connect-timeout 2 --max-time 4 `
        "http://${target}:8080/health" 2>$null
    $code = ($raw | Select-Object -Last 1).Trim()
    $accessible = if ($code -match "^2") { "YES (POLICY FAIL)" } else { "NO (blocked)" }
    $color = if ($code -match "^2") { "Red" } else { "Green" }
    Write-Host ("  attacker -> {0,-10}: HTTP {1} [{2}]" -f $target, $code, $accessible) -ForegroundColor $color

    Write-Csv -Phase "post-hstp-lateral" -Step "lateral" `
              -HttpCode $code -RespMs 0 -Depth 0 -WavePhase "post" `
              -Notes "attacker->$target"
}

# Cleanup
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker  -n $NS --grace-period=0 --force 2>$null | Out-Null

# 요약
$allRows    = Get-Content $CSV_FILE | Select-Object -Skip 1
$totalCnt   = $allRows.Count
$successCnt = ($allRows | Where-Object { $_ -match ",200," }).Count
$successPct = if ($totalCnt -gt 0) { [math]::Round($successCnt / $totalCnt * 100, 1) } else { 0 }
$blockedCnt = ($allRows | Where-Object { $_ -match "attacker" -and $_ -notmatch ",200," }).Count

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: HSTP Safe Deactivation"            -ForegroundColor Green
Write-Host "  Wave status    : $finalPhase"
Write-Host "  Measurements   : $totalCnt"
Write-Host "  Success rate   : ${successPct}%"
Write-Host "  Post-HSTP blocked: $blockedCnt / 4 services" -ForegroundColor Green
Write-Host "  Output CSV     : $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
