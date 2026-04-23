<#
.SYNOPSIS
    Week 2 — Activation Order Experiment
    서비스를 지정된 순서로 scale-up 하면서 요청 성공/실패율과 Attack Window를 측정한다.

.PARAMETER Order
    활성화 순서: A1 (정상), A2 (역순), A3 (임의)

.PARAMETER IntervalSec
    각 서비스 활성화 후 측정 지속 시간 (기본값: 20초)

.PARAMETER MeasureAfterSec
    전체 활성화 완료 후 추가 측정 시간 (기본값: 30초)

.EXAMPLE
    .\05-activation-experiment.ps1 -Order A1
    .\05-activation-experiment.ps1 -Order A2 -IntervalSec 20
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("A1","A2","A3")]
    [string]$Order,

    [int]$IntervalSec = 20,
    [int]$MeasureAfterSec = 30
)

$ErrorActionPreference = "Continue"

$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path $PSScriptRoot "..\logs"
$CSV_FILE  = Join-Path $LOG_DIR "activation-$Order-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

# ── Activation Order 정의 ────────────────────────────────────────────
$ORDERS = @{
    "A1" = @("auth","campaign","package","deploy")   # 정상: upstream first
    "A2" = @("deploy","package","campaign","auth")   # 역순: downstream first  ← 최고 위험
    "A3" = @("campaign","deploy","auth","package")   # 임의
}
$ORDER_DESC = @{
    "A1" = "Normal     (auth -> campaign -> package -> deploy)"
    "A2" = "Reverse    (deploy -> package -> campaign -> auth)  ** HIGH RISK **"
    "A3" = "Arbitrary  (campaign -> deploy -> auth -> package)"
}

$sequence    = $ORDERS[$Order]
$experimentId = "ACT-$Order-$TIMESTAMP"
$startTime    = $null   # set after scale-down completes

# ── CSV 초기화 ────────────────────────────────────────────────────────
$header = "experiment_id,phase,activation_order,step,step_service,elapsed_sec," +
          "http_status,response_time_ms,pipeline_depth,services_up,error"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

function Write-Csv {
    param(
        [string]$Phase, [string]$Step, [string]$StepSvc,
        [string]$HttpCode, [int]$RespMs, [int]$Depth,
        [string[]]$ServicesUp, [string]$Err = ""
    )
    $elapsed  = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    $svcList  = if ($ServicesUp.Count -gt 0) { $ServicesUp -join "+" } else { "none" }
    $row = "$experimentId,$Phase,$Order,$Step,$StepSvc,$elapsed," +
           "$HttpCode,$RespMs,$Depth,$svcList,$Err"
    Add-Content -Path $CSV_FILE -Value $row -Encoding UTF8
}

# ── 파이프라인 요청 측정 ──────────────────────────────────────────────
function Invoke-PipelineMeasure {
    param([string]$Phase, [string]$Step, [string]$StepSvc, [string[]]$ServicesUp)

    $t0 = Get-Date
    try {
        # load-gen 파드에서 auth:8080/call 호출
        $raw = kubectl exec load-gen -n $NS -- `
            curl -s -o /tmp/r.txt -w "%{http_code}" `
            --connect-timeout 2 --max-time 5 `
            http://auth:8080/call 2>$null
        $httpCode = ($raw | Select-Object -Last 1).Trim()
        $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds

        # 응답 본문에서 파이프라인 깊이 측정
        $body  = kubectl exec load-gen -n $NS -- cat /tmp/r.txt 2>$null
        $depth = 0
        foreach ($s in @("auth","campaign","package","deploy")) {
            if ($body -match $s) { $depth++ }
        }

        Write-Csv -Phase $Phase -Step $Step -StepSvc $StepSvc `
                  -HttpCode $httpCode -RespMs $respMs -Depth $depth `
                  -ServicesUp $ServicesUp
        return $httpCode
    } catch {
        Write-Csv -Phase $Phase -Step $Step -StepSvc $StepSvc `
                  -HttpCode "error" -RespMs 0 -Depth 0 `
                  -ServicesUp $ServicesUp -Err "exec_failed"
        return "error"
    }
}

# ── 헤더 출력 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 2 — Activation Experiment : $Order"   -ForegroundColor Cyan
Write-Host "  $($ORDER_DESC[$Order])"                     -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: 모든 서비스 scale down ───────────────────────────────────
Write-Host "[SETUP] Scaling down all services..." -ForegroundColor Yellow
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=0 2>&1 | Out-Null
}

Write-Host "[SETUP] Waiting for pods to terminate..."
$waited = 0
do {
    Start-Sleep -Seconds 3
    $waited += 3
    $alive = kubectl get pods -n $NS --field-selector=status.phase=Running `
                 --no-headers 2>$null | Where-Object { $_ -match "auth|campaign|package|deploy" }
} while ($alive -and $waited -lt 90)

Write-Host "[SETUP] All service pods terminated. ($waited s)`n"

# ── Step 2: load-gen 파드 배포 ───────────────────────────────────────
Write-Host "[MEASURE] Deploying load-gen pod..."
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2

kubectl run load-gen -n $NS --image=curlimages/curl:8.6.0 `
    --restart=Never --command -- sleep 3600 2>&1 | Out-Null

$lgWaited = 0
do {
    Start-Sleep -Seconds 3
    $lgWaited += 3
    $lgStatus = kubectl get pod load-gen -n $NS --no-headers 2>$null
} while ($lgStatus -notmatch "Running" -and $lgWaited -lt 60)

Write-Host "[MEASURE] load-gen ready ($lgWaited s).`n"

# ── 실험 시작 타이머 ─────────────────────────────────────────────────
$startTime = Get-Date

# ── Step 3: 기준선 측정 (all down) ───────────────────────────────────
Write-Host "[BASELINE] Measuring with all services down (3 samples)..."
for ($i = 0; $i -lt 3; $i++) {
    $code = Invoke-PipelineMeasure -Phase "baseline" -Step "baseline" `
                -StepSvc "none" -ServicesUp @()
    Write-Host "  baseline[$i] -> HTTP $code"
    Start-Sleep -Seconds 2
}
Write-Host ""

# ── Step 4: 순서대로 서비스 활성화 + 측정 ───────────────────────────
$activeServices  = [System.Collections.ArrayList]@()
$attackWindowStart = $null   # downstream 첫 노출 시점 (A2에서 deploy가 올라올 때)
$attackWindowEnd   = $null   # auth가 올라오는 시점

for ($idx = 0; $idx -lt $sequence.Count; $idx++) {
    $svc     = $sequence[$idx]
    $stepNum = $idx + 1

    Write-Host "[ACTIVATE] Step $stepNum/$($sequence.Count): scaling up '$svc'..." -ForegroundColor Green
    $scaleAt = Get-Date
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null

    # rollout 완료 대기
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
    $readySec = [math]::Round(((Get-Date) - $scaleAt).TotalSeconds, 1)
    Write-Host "  '$svc' ready in ${readySec}s"

    $null = $activeServices.Add($svc)

    # Attack Window 기록 (A2: deploy 올라올 때 시작, auth 올라올 때 끝)
    if ($svc -eq "deploy" -and $attackWindowStart -eq $null) {
        $attackWindowStart = (Get-Date) - $startTime
    }
    if ($svc -eq "auth" -and $attackWindowEnd -eq $null) {
        $attackWindowEnd = (Get-Date) - $startTime
    }

    # IntervalSec 동안 측정
    Write-Host "  Measuring for ${IntervalSec}s..."
    $measureEnd = (Get-Date).AddSeconds($IntervalSec)
    $count = 0
    while ((Get-Date) -lt $measureEnd) {
        $code = Invoke-PipelineMeasure -Phase "transition" `
                    -Step "step$stepNum" -StepSvc $svc `
                    -ServicesUp $activeServices.ToArray()
        if ($count % 4 -eq 0) {
            $svcStr = $activeServices -join "+"
            Write-Host "  [step$stepNum] HTTP $code | up: $svcStr"
        }
        $count++
        Start-Sleep -Seconds 2
    }
    Write-Host ""
}

# ── Step 5: 완전 활성화 후 추가 측정 ────────────────────────────────
Write-Host "[POST] All services up. Measuring stable state for ${MeasureAfterSec}s..." -ForegroundColor Cyan
$measureEnd = (Get-Date).AddSeconds($MeasureAfterSec)
$count = 0
while ((Get-Date) -lt $measureEnd) {
    $code = Invoke-PipelineMeasure -Phase "post" -Step "post" -StepSvc "all" `
                -ServicesUp $sequence
    if ($count % 5 -eq 0) { Write-Host "  [post] HTTP $code" }
    $count++
    Start-Sleep -Seconds 2
}

# ── Step 6: Cleanup load-gen ─────────────────────────────────────────
Write-Host "`n[CLEANUP] Removing load-gen pod..."
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>&1 | Out-Null

# ── 결과 요약 ────────────────────────────────────────────────────────
$totalSec = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
$rows     = (Get-Content $CSV_FILE | Measure-Object -Line).Lines - 1

# Attack Window 계산
$awSec = "N/A"
if ($attackWindowStart -ne $null -and $attackWindowEnd -ne $null) {
    $awSec = [math]::Round(($attackWindowEnd - $attackWindowStart).TotalSeconds, 1)
} elseif ($Order -eq "A1") {
    $awSec = "0 (auth first, no window)"
}

# 성공률 계산
$allRows    = Get-Content $CSV_FILE | Select-Object -Skip 1
$successCnt = ($allRows | Where-Object { $_ -match ",200," }).Count
$totalCnt   = $allRows.Count
$successPct = if ($totalCnt -gt 0) { [math]::Round($successCnt / $totalCnt * 100, 1) } else { 0 }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: Activation $Order"                  -ForegroundColor Green
Write-Host "  Order         : $($ORDER_DESC[$Order])"
Write-Host "  Total time    : ${totalSec}s"
Write-Host "  Measurements  : $rows data points"
Write-Host "  Success rate  : ${successPct}% ($successCnt / $totalCnt)"
Write-Host "  Attack Window : ${awSec}s"
Write-Host "  Output CSV    : $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
