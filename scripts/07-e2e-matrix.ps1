<#
.SYNOPSIS
    Week 2 - End-to-End Matrix Experiment (9 combos)
    Activation 3 x Deactivation 3 = 9 combos

.PARAMETER ActivationOrders
    A1, A2, A3 (default: all)

.PARAMETER DeactivationOrders
    D1, D2, D3 (default: all)

.PARAMETER IntervalSec
    Measurement seconds per step (default: 15)

.EXAMPLE
    .\07-e2e-matrix.ps1
    .\07-e2e-matrix.ps1 -ActivationOrders A1,A2 -DeactivationOrders D1,D2
    .\07-e2e-matrix.ps1 -IntervalSec 10
#>
param(
    [string[]]$ActivationOrders   = @("A1","A2","A3"),
    [string[]]$DeactivationOrders = @("D1","D2","D3"),
    [int]$IntervalSec = 15
)

$ErrorActionPreference = "Continue"

$SCRIPT_DIR  = (Get-Item (Join-Path $PWD ".")).FullName
$LOG_DIR     = Join-Path $SCRIPT_DIR "..\logs"
$TIMESTAMP   = Get-Date -Format "yyyyMMdd-HHmmss"
$SUMMARY_CSV = Join-Path $LOG_DIR "e2e-matrix-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR | Out-Null
}

$ACTIVATION_DESC = @{
    "A1" = "Normal (auth->campaign->package->deploy)"
    "A2" = "Reverse (deploy->package->campaign->auth)"
    "A3" = "Arbitrary (campaign->deploy->auth->package)"
}
$DEACTIVATION_DESC = @{
    "D1" = "Drain (deploy->package->campaign->auth)"
    "D2" = "Reverse (auth->campaign->package->deploy)"
    "D3" = "Arbitrary (package->auth->deploy->campaign)"
}

$summaryHeader = "combo_id,activation_order,deactivation_order,activation_csv,deactivation_csv,act_success_pct,act_attack_window_sec,deact_success_pct,deact_security_hole_sec,act_total_sec,deact_total_sec,status"
Set-Content -Path $SUMMARY_CSV -Value $summaryHeader -Encoding UTF8

function Get-CsvMetrics {
    param([string]$CsvPath)

    $result = @{ SuccessPct = "N/A"; TotalSec = "N/A" }

    if ([string]::IsNullOrEmpty($CsvPath) -or -not (Test-Path $CsvPath)) {
        return $result
    }

    $rows       = Get-Content $CsvPath | Select-Object -Skip 1
    $totalCnt   = $rows.Count
    $successCnt = ($rows | Where-Object { $_ -match ",200," }).Count

    if ($totalCnt -gt 0) {
        $result.SuccessPct = [math]::Round($successCnt / $totalCnt * 100, 1)
    } else {
        $result.SuccessPct = 0
    }

    $maxElapsed = 0
    foreach ($row in $rows) {
        $cols = $row -split ","
        if ($cols.Count -ge 6) {
            $val = 0
            if ([double]::TryParse($cols[5], [ref]$val)) {
                if ($val -gt $maxElapsed) { $maxElapsed = $val }
            }
        }
    }
    $result.TotalSec = [math]::Round($maxElapsed, 0)

    return $result
}

$totalCombos = $ActivationOrders.Count * $DeactivationOrders.Count
$comboNum    = 0
$results     = [System.Collections.ArrayList]@()

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Week 2 - E2E Matrix Experiment" -ForegroundColor Cyan
Write-Host "  Combos: $totalCombos"
Write-Host "  Summary CSV -> $SUMMARY_CSV"
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($actOrder in $ActivationOrders) {
    foreach ($deactOrder in $DeactivationOrders) {
        $comboNum++
        $comboId = "$actOrder-$deactOrder"
        $status  = "ok"

        Write-Host "-------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  COMBO $comboNum/$totalCombos : $comboId" -ForegroundColor Magenta
        Write-Host "  ACT  : $($ACTIVATION_DESC[$actOrder])"
        Write-Host "  DEACT: $($DEACTIVATION_DESC[$deactOrder])"
        Write-Host "-------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""

        # Activation experiment
        Write-Host "[E2E] Running ACTIVATION $actOrder ..." -ForegroundColor Green
        $actCsvPath = ""
        try {
            & "$SCRIPT_DIR\05-activation-experiment.ps1" -Order $actOrder -IntervalSec $IntervalSec -MeasureAfterSec 20
            $actCsvGlob = Join-Path $LOG_DIR "activation-$actOrder-*.csv"
            $actCsvFile = Get-ChildItem $actCsvGlob -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending |
                          Select-Object -First 1
            if ($actCsvFile) { $actCsvPath = $actCsvFile.FullName }
        } catch {
            Write-Host "  [ERROR] Activation $actOrder failed: $_" -ForegroundColor Red
            $status = "act_error"
        }

        Write-Host "`n[E2E] Stabilizing (10s)..."
        Start-Sleep -Seconds 10

        # Deactivation experiment
        Write-Host "[E2E] Running DEACTIVATION $deactOrder ..." -ForegroundColor Red
        $deactCsvPath = ""
        try {
            & "$SCRIPT_DIR\06-deactivation-experiment.ps1" -Order $deactOrder -IntervalSec $IntervalSec -MeasureBeforeSec 15
            $deactCsvGlob = Join-Path $LOG_DIR "deactivation-$deactOrder-*.csv"
            $deactCsvFile = Get-ChildItem $deactCsvGlob -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending |
                            Select-Object -First 1
            if ($deactCsvFile) { $deactCsvPath = $deactCsvFile.FullName }
        } catch {
            Write-Host "  [ERROR] Deactivation $deactOrder failed: $_" -ForegroundColor Red
            if ($status -eq "ok") { $status = "deact_error" }
        }

        # Extract metrics
        $actMetrics   = Get-CsvMetrics -CsvPath $actCsvPath
        $deactMetrics = Get-CsvMetrics -CsvPath $deactCsvPath

        if ($actOrder -eq "A1") { $actAttackWindow = "0" } else { $actAttackWindow = "measured_in_csv" }
        if ($deactOrder -eq "D1") { $deactSecHole = "0" } else { $deactSecHole = "measured_in_csv" }

        # Write summary row
        $row = "$comboId,$actOrder,$deactOrder,$actCsvPath,$deactCsvPath,$($actMetrics.SuccessPct),$actAttackWindow,$($deactMetrics.SuccessPct),$deactSecHole,$($actMetrics.TotalSec),$($deactMetrics.TotalSec),$status"
        Add-Content -Path $SUMMARY_CSV -Value $row -Encoding UTF8

        $entry = [PSCustomObject]@{
            Combo        = $comboId
            ActSuccess   = $actMetrics.SuccessPct
            DeactSuccess = $deactMetrics.SuccessPct
            Status       = $status
        }
        $null = $results.Add($entry)

        Write-Host "`n[E2E] Combo $comboId done. Status: $status`n"

        if ($comboNum -lt $totalCombos) {
            Write-Host "[E2E] Waiting 15s before next combo..."
            Start-Sleep -Seconds 15
        }
    }
}

# Final summary
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  E2E MATRIX COMPLETE - $totalCombos combos" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-12} {1,-12} {2,-12} {3}" -f "Combo","Act%","Deact%","Status")
Write-Host ("  {0,-12} {1,-12} {2,-12} {3}" -f "-----","----","-----","------")
foreach ($r in $results) {
    if ($r.Status -eq "ok") {
        Write-Host ("  {0,-12} {1,-12} {2,-12} {3}" -f $r.Combo,$r.ActSuccess,$r.DeactSuccess,$r.Status)
    } else {
        Write-Host ("  {0,-12} {1,-12} {2,-12} {3}" -f $r.Combo,$r.ActSuccess,$r.DeactSuccess,$r.Status) -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "  Summary CSV: $SUMMARY_CSV"
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
