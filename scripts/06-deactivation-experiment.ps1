<#
.SYNOPSIS
    Week 2 — Deactivation Order Experiment
    모든 서비스가 실행 중인 상태에서 지정된 순서로 scale-down 하면서
    Security Hole Duration과 요청 실패율을 측정한다.

.PARAMETER Order
    비활성화 순서: D1 (drain 정상), D2 (upstream first), D3 (임의)

.PARAMETER IntervalSec
    각 서비스 비활성화 후 측정 지속 시간 (기본값: 20초)

.PARAMETER MeasureBeforeSec
    비활성화 시작 전 안정 상태 측정 시간 (기본값: 20초)

.EXAMPLE
    .\06-deactivation-experiment.ps1 -Order D1
    .\06-deactivation-experiment.ps1 -Order D2 -IntervalSec 20
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("D1","D2","D3")]
    [string]$Order,

    [int]$IntervalSec    = 20,
    [int]$MeasureBeforeSec = 20
)

$ErrorActionPreference = "Continue"

$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path $PSScriptRoot "..\logs"
$CSV_FILE  = Join-Path $LOG_DIR "deactivation-$Order-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

# ── Deactivation Order 정의 ──────────────────────────────────────────
$ORDERS = @{
    "D1" = @("deploy","package","campaign","auth")   # 정상 drain: downstream first
    "D2" = @("auth","campaign","package","deploy")   # 역순: upstream first  ← 최고 위험
    "D3" = @("package","auth","deploy","campaign")   # 임의
}
$ORDER_DESC = @{
    "D1" = "Normal drain  (deploy -> package -> campaign -> auth)"
    "D2" = "Reverse       (auth -> campaign -> package -> deploy)  ** HIGH RISK **"
    "D3" = "Arbitrary     (package -> auth -> deploy -> campaign)"
}

$sequence     = $ORDERS[$Order]
$allServices  = @("auth","campaign","package","deploy")
$experimentId = "DEACT-$Order-$TIMESTAMP"
$startTime    = $null

# ── CSV 초기화 ────────────────────────────────────────────────────────
$header = "experiment_id,phase,deactivation_order,step,step_service,elapsed_sec," +
          "http_status,response_time_ms,pipeline_depth,services_up,error"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

function Write-Csv {
    param(
        [string]$Phase, [string]$Step, [string]$StepSvc,
        [string]$HttpCode, [int]$RespMs, [int]$Depth,
        [string[]]$ServicesUp, [string]$Err = ""
    )
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    $svcList = if ($ServicesUp.Count -gt 0) { $ServicesUp -join "+" } else { "none" }
    $row = "$experimentId,$Phase,$Order,$Step,$StepSvc,$elapsed," +
           "$HttpCode,$RespMs,$Depth,$svcList,$Err"
    Add-Content -Path $CSV_FILE -Value $row -Encoding UTF8
}

function Invoke-PipelineMeasure {
    param([string]$Phase, [string]$Step, [string]$StepSvc, [string[]]$ServicesUp)

    $t0 = Get-Date
    try {
        $raw = kubectl exec load-gen -n $NS -- `
            curl -s -o /tmp/r.txt -w "%{http_code}" `
            --connect-timeout 2 --max-time 5 `
            http://auth:8080/call 2>$null
        $httpCode = ($raw | Select-Object -Last 1).Trim()
        $respMs   = [int]((Get-Date) - $t0).TotalMilliseconds

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
Write-Host "  Week 2 — Deactivation Experiment : $Order"  -ForegroundColor Cyan
Write-Host "  $($ORDER_DESC[$Order])"                      -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: 모든 서비스 scale up (시작 상태 보장) ────────────────────
Write-Host "[SETUP] Ensuring all services are running (scale to 1)..." -ForegroundColor Yellow
foreach ($svc in $allServices) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in $allServices) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}
Write-Host "[SETUP] All services ready.`n"

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

# ── Step 3: 안정 상태 기준선 측정 ────────────────────────────────────
Write-Host "[PRE] Measuring stable state for ${MeasureBeforeSec}s (all services up)..."
$measureEnd = (Get-Date).AddSeconds($MeasureBeforeSec)
$count = 0
while ((Get-Date) -lt $measureEnd) {
    $code = Invoke-PipelineMeasure -Phase "pre" -Step "pre" -StepSvc "all" `
                -ServicesUp $allServices
    if ($count % 4 -eq 0) { Write-Host "  [pre] HTTP $code | all services up" }
    $count++
    Start-Sleep -Seconds 2
}
Write-Host ""

# ── Step 4: 순서대로 서비스 비활성화 + 측정 ─────────────────────────
$activeServices = [System.Collections.ArrayList]@($allServices)
$secHoleStart   = $null   # auth 제거 시점
$secHoleEnd     = $null   # deploy 제거 시점

for ($idx = 0; $idx -lt $sequence.Count; $idx++) {
    $svc     = $sequence[$idx]
    $stepNum = $idx + 1

    Write-Host "[DEACTIVATE] Step $stepNum/$($sequence.Count): scaling down '$svc'..." -ForegroundColor Red
    kubectl scale deployment $svc -n $NS --replicas=0 2>&1 | Out-Null

    # Security Hole Window 기록 (D2: auth 제거되는 순간 시작)
    if ($svc -eq "auth" -and $secHoleStart -eq $null) {
        $secHoleStart = (Get-Date) - $startTime
    }
    if ($svc -eq "deploy" -and $secHoleEnd -eq $null) {
        $secHoleEnd = (Get-Date) - $startTime
    }

    $null = $activeServices.Remove($svc)

    # IntervalSec 동안 측정
    Write-Host "  Measuring for ${IntervalSec}s..."
    $measureEnd = (Get-Date).AddSeconds($IntervalSec)
    $count = 0
    while ((Get-Date) -lt $measureEnd) {
        $code = Invoke-PipelineMeasure -Phase "transition" `
                    -Step "step$stepNum" -StepSvc $svc `
                    -ServicesUp $activeServices.ToArray()
        if ($count % 4 -eq 0) {
            $svcStr = if ($activeServices.Count -gt 0) { $activeServices -join "+" } else { "none" }
            Write-Host "  [step$stepNum] HTTP $code | remaining: $svcStr"
        }
        $count++
        Start-Sleep -Seconds 2
    }
    Write-Host ""
}

# ── Step 5: 완전 비활성화 후 측정 ────────────────────────────────────
Write-Host "[POST] All services down. Measuring for 15s..." -ForegroundColor Cyan
$measureEnd = (Get-Date).AddSeconds(15)
$count = 0
while ((Get-Date) -lt $measureEnd) {
    $code = Invoke-PipelineMeasure -Phase "post" -Step "post" -StepSvc "none" `
                -ServicesUp @()
    if ($count % 3 -eq 0) { Write-Host "  [post] HTTP $code" }
    $count++
    Start-Sleep -Seconds 2
}

# ── Step 6: Cleanup load-gen ─────────────────────────────────────────
Write-Host "`n[CLEANUP] Removing load-gen pod..."
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>&1 | Out-Null

# ── 결과 요약 ────────────────────────────────────────────────────────
$totalSec = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
$rows     = (Get-Content $CSV_FILE | Measure-Object -Line).Lines - 1

$shSec = "N/A"
if ($secHoleStart -ne $null -and $secHoleEnd -ne $null) {
    $shSec = [math]::Round(($secHoleEnd - $secHoleStart).TotalSeconds, 1)
} elseif ($Order -eq "D1") {
    $shSec = "0 (deploy drained first, auth last)"
}

$allRows    = Get-Content $CSV_FILE | Select-Object -Skip 1
$successCnt = ($allRows | Where-Object { $_ -match ",200," }).Count
$totalCnt   = $allRows.Count
$successPct = if ($totalCnt -gt 0) { [math]::Round($successCnt / $totalCnt * 100, 1) } else { 0 }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: Deactivation $Order"                -ForegroundColor Green
Write-Host "  Order              : $($ORDER_DESC[$Order])"
Write-Host "  Total time         : ${totalSec}s"
Write-Host "  Measurements       : $rows data points"
Write-Host "  Success rate       : ${successPct}% ($successCnt / $totalCnt)"
Write-Host "  Security Hole      : ${shSec}s"
Write-Host "  Output CSV         : $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
