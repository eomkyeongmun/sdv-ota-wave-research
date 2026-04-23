<#
.SYNOPSIS
    Week 3 - Lateral Movement During D2 Transition
    D2 deactivation (auth -> campaign -> package -> deploy) 진행 중
    공격자 pod가 내부 서비스에 직접 접근을 시도한다.

    핵심 시나리오:
      auth 제거 직후 ~ deploy 제거 전 = Security Hole (~51s)
      이 구간에서 attacker -> deploy 직접 접근 성공 여부 측정

.PARAMETER IntervalSec
    각 서비스 제거 후 측정 시간 (기본값: 20초)

.EXAMPLE
    .\09-lateral-movement-during-transition.ps1
    .\09-lateral-movement-during-transition.ps1 -IntervalSec 25
#>
param(
    [int]$IntervalSec = 20
)

$ErrorActionPreference = "Continue"

$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$CSV_FILE  = Join-Path $LOG_DIR "lateral-movement-transition-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

# D2 deactivation 순서: auth -> campaign -> package -> deploy
$D2_ORDER   = @("auth", "campaign", "package", "deploy")
$ALL_SVC    = @("auth", "campaign", "package", "deploy")

# 공격 타겟: 각 단계에서 살아있는 downstream 서비스에 직접 접근 시도
# auth 제거 후: campaign, package, deploy 에 직접 접근
# campaign 제거 후: package, deploy 에 직접 접근
# ...

$header = "experiment_id,phase,deact_step,removed_service,attacker_target,elapsed_sec,http_status,response_time_ms,accessible,services_remaining,notes"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

$experimentId = "LATERAL-TRANSITION-$TIMESTAMP"
$startTime    = $null

function Write-Csv {
    param([string]$Phase, [string]$Step, [string]$Removed,
          [string]$Target, [string]$HttpCode, [int]$RespMs,
          [string]$Accessible, [string[]]$Remaining, [string]$Notes = "")
    $elapsed  = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    $remStr   = if ($Remaining.Count -gt 0) { $Remaining -join "+" } else { "none" }
    $row = "$experimentId,$Phase,$Step,$Removed,$Target,$elapsed,$HttpCode,$RespMs,$Accessible,$remStr,$Notes"
    Add-Content -Path $CSV_FILE -Value $row -Encoding UTF8
}

function Invoke-AttackAttempt {
    param([string]$Phase, [string]$Step, [string]$Removed,
          [string]$Target, [string[]]$Remaining)
    $t0 = Get-Date
    $raw = kubectl exec attacker -n $NS -- `
        curl -s -o /tmp/r.txt -w "%{http_code}" `
        --connect-timeout 2 --max-time 5 `
        "http://${Target}:8080/health" 2>$null
    $httpCode = ($raw | Select-Object -Last 1).Trim()
    $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds
    $accessible = if ($httpCode -match "^2") { "YES" } else { "NO" }

    Write-Csv -Phase $Phase -Step $Step -Removed $Removed `
              -Target $Target -HttpCode $httpCode -RespMs $respMs `
              -Accessible $accessible -Remaining $Remaining
    return $accessible
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 3 - Lateral Movement During D2"       -ForegroundColor Cyan
Write-Host "  D2: auth->campaign->package->deploy"        -ForegroundColor Yellow
Write-Host "  Attacker target: downstream services"       -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: 모든 서비스 정상 실행
Write-Host "[SETUP] Ensuring all services are running..."
foreach ($svc in $ALL_SVC) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in $ALL_SVC) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}
Write-Host "[SETUP] All services ready.`n"

# Step 2: 공격자 pod 배포
Write-Host "[ATTACKER] Deploying attacker pod..."
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

$startTime = Get-Date

# Step 3: 안정 상태 기준선 (모두 정상 실행, auth 통해서만 접근 가능해야 정상)
Write-Host "[PRE] Baseline - all services up, measuring direct access..."
for ($i = 0; $i -lt 3; $i++) {
    foreach ($target in @("deploy", "package", "campaign")) {
        $result = Invoke-AttackAttempt -Phase "pre" -Step "pre" -Removed "none" `
                      -Target $target -Remaining $ALL_SVC
        Write-Host ("  [pre] attacker -> {0,-10} : {1}" -f $target, $result) -ForegroundColor $(if ($result -eq "YES") { "Red" } else { "Green" })
    }
    Start-Sleep -Seconds 3
}
Write-Host ""

# Step 4: D2 순서로 서비스 제거하면서 lateral movement 시도
$remaining = [System.Collections.ArrayList]@($ALL_SVC)

for ($idx = 0; $idx -lt $D2_ORDER.Count; $idx++) {
    $removed = $D2_ORDER[$idx]
    $stepNum = $idx + 1

    Write-Host "[D2-STEP $stepNum/4] Removing '$removed'..." -ForegroundColor Red
    kubectl scale deployment $removed -n $NS --replicas=0 2>&1 | Out-Null
    $null = $remaining.Remove($removed)

    $remainingArr = $remaining.ToArray()

    Write-Host "  Remaining services: $($remainingArr -join ' + ')"
    Write-Host "  Measuring lateral movement for ${IntervalSec}s..."

    $measureEnd = (Get-Date).AddSeconds($IntervalSec)
    $count = 0

    while ((Get-Date) -lt $measureEnd) {
        # 살아있는 모든 서비스에 직접 접근 시도
        foreach ($target in $remainingArr) {
            $result = Invoke-AttackAttempt -Phase "transition" -Step "step$stepNum" `
                          -Removed $removed -Target $target -Remaining $remainingArr

            if ($count % 3 -eq 0) {
                $color = if ($result -eq "YES") { "Red" } else { "Green" }
                Write-Host ("  [step{0}] attacker -> {1,-10} : {2}" -f $stepNum, $target, $result) -ForegroundColor $color
            }
        }
        $count++
        Start-Sleep -Seconds 2
    }
    Write-Host ""
}

# Step 5: Cleanup
Write-Host "[CLEANUP] Removing attacker pod..."
kubectl delete pod attacker -n $NS --grace-period=0 --force 2>&1 | Out-Null

# 결과 요약
$allRows    = Get-Content $CSV_FILE | Select-Object -Skip 1
$rows       = $allRows.Count
$yesRows    = $allRows | Where-Object { $_ -match ",YES," }
$noRows     = $allRows | Where-Object { $_ -match ",NO," }
$accessCnt  = $yesRows.Count
$blockCnt   = $noRows.Count

# Security hole: auth 제거 후 deploy 접근 성공한 첫 번째 ~ 마지막 시간
$holeRows   = $yesRows | Where-Object { $_ -match ",deploy," -and $_ -match "step" }
$holeStart  = $null
$holeEnd    = $null
foreach ($r in $holeRows) {
    $cols = $r -split ","
    if ($cols.Count -ge 6) {
        $t = 0
        if ([double]::TryParse($cols[5], [ref]$t)) {
            if ($holeStart -eq $null -or $t -lt $holeStart) { $holeStart = $t }
            if ($holeEnd -eq $null -or $t -gt $holeEnd)     { $holeEnd = $t }
        }
    }
}
$holeDuration = if ($holeStart -ne $null -and $holeEnd -ne $null) {
    [math]::Round($holeEnd - $holeStart, 1)
} else { "N/A" }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: Lateral Movement During D2"        -ForegroundColor Green
Write-Host "  Total measurements  : $rows"
Write-Host "  Direct access YES   : $accessCnt" -ForegroundColor Red
Write-Host "  Blocked (NO)        : $blockCnt"  -ForegroundColor Green
Write-Host "  deploy access window: ${holeDuration}s" -ForegroundColor $(if ($holeDuration -ne "N/A" -and $holeDuration -gt 0) { "Red" } else { "Green" })
Write-Host "  Output CSV          : $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
if ($accessCnt -gt 0) {
    Write-Host "  CONFIRMED: Attacker can reach internal services" -ForegroundColor Red
    Write-Host "  during D2 transition without any policy."        -ForegroundColor Red
    Write-Host ""
    Write-Host "  -> Week 4: Implement Hierarchical Safe Transition Protocol" -ForegroundColor Yellow
}
Write-Host ""
