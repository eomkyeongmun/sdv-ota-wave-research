<#
.SYNOPSIS
    KCI 논문용 반복 실험 실행기
    scripts 15, 17, 18을 N회 반복 실행하여 mean +/- std 통계를 산출한다.

.PARAMETER Runs
    각 실험 반복 횟수 (기본값: 5)

.EXAMPLE
    .\19-repeat-experiments.ps1
    .\19-repeat-experiments.ps1 -Runs 5
#>

param(
    [int]$Runs = 5
)

$ErrorActionPreference = "Continue"
$SCRIPT_DIR   = $PSScriptRoot
$PROJECT_ROOT = (Get-Item (Join-Path $SCRIPT_DIR "..")).FullName
$LOGS_DIR     = Join-Path $PROJECT_ROOT "logs"
$TIMESTAMP    = Get-Date -Format "yyyyMMdd-HHmmss"
$STATS_CSV    = Join-Path $LOGS_DIR "kci-stats-$TIMESTAMP.csv"
$RAW_CSV      = Join-Path $LOGS_DIR "kci-raw-$TIMESTAMP.csv"

if (-not (Test-Path $LOGS_DIR)) { New-Item -ItemType Directory -Path $LOGS_DIR | Out-Null }

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  KCI Repeat Experiment Runner  (N=$Runs)"        -ForegroundColor Cyan
Write-Host "  Experiments: 17 + 18 + 15"                      -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

Set-Content -Path $RAW_CSV -Value "run,experiment,metric,value" -Encoding UTF8

$data = @{
    hole_D1    = [System.Collections.Generic.List[double]]::new()
    hole_D2    = [System.Collections.Generic.List[double]]::new()
    hole_D3    = [System.Collections.Generic.List[double]]::new()
    deny_gap   = [System.Collections.Generic.List[double]]::new()
    allow_gap  = [System.Collections.Generic.List[double]]::new()
    np_hole    = [System.Collections.Generic.List[double]]::new()
    np_block   = [System.Collections.Generic.List[double]]::new()
    np_success = [System.Collections.Generic.List[double]]::new()
    h_block    = [System.Collections.Generic.List[double]]::new()
    h_success  = [System.Collections.Generic.List[double]]::new()
    h_risk     = [System.Collections.Generic.List[double]]::new()
    hm_block   = [System.Collections.Generic.List[double]]::new()
    hm_success = [System.Collections.Generic.List[double]]::new()
    hm_risk    = [System.Collections.Generic.List[double]]::new()
}

function Calc-Stats {
    param([System.Collections.Generic.List[double]]$Values)
    $n = $Values.Count
    if ($n -eq 0) { return @{ mean=0; std=0; min=0; max=0; n=0 } }
    $mean = 0.0
    foreach ($v in $Values) { $mean += $v }
    $mean = $mean / $n
    $var = 0.0
    foreach ($v in $Values) { $var += [math]::Pow($v - $mean, 2) }
    $std = if ($n -gt 1) { [math]::Round([math]::Sqrt($var / ($n - 1)), 2) } else { 0.0 }
    $min = $Values[0]; $max = $Values[0]
    foreach ($v in $Values) {
        if ($v -lt $min) { $min = $v }
        if ($v -gt $max) { $max = $v }
    }
    return @{
        mean = [math]::Round($mean, 2)
        std  = $std
        min  = [math]::Round($min, 2)
        max  = [math]::Round($max, 2)
        n    = $n
    }
}

function Get-LatestCsv {
    param([string]$Pattern)
    $files = Get-ChildItem -Path $LOGS_DIR -Filter $Pattern -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    if ($files) { return $files[0].FullName } else { return $null }
}

function Parse-Script17 {
    param([string[]]$Lines)
    $holes = @{ D1=$null; D2=$null; D3=$null }
    $cur = $null
    foreach ($line in $Lines) {
        if ($line -match "---\s*(D[123])\s*:") { $cur = $Matches[1] }
        if ($line -match "Total hole duration:\s*([\d.]+)s" -and $cur) {
            $holes[$cur] = [double]$Matches[1]
        }
    }
    return $holes
}

function Parse-Script18 {
    param([string[]]$Lines)
    $deny = 0.0; $allow = 0.0
    foreach ($line in $Lines) {
        if ($line -match "DENY propagation gap.*?:\s*([\d.]+)s")  { $deny  = [double]$Matches[1] }
        if ($line -match "ALLOW propagation gap.*?:\s*([\d.]+)s") { $allow = [double]$Matches[1] }
    }
    return @{ deny=$deny; allow=$allow }
}

for ($run = 1; $run -le $Runs; $run++) {
    Write-Host ""
    Write-Host "-------------------------------------------------" -ForegroundColor Magenta
    Write-Host "  Run $run / $Runs" -ForegroundColor Magenta
    Write-Host "-------------------------------------------------" -ForegroundColor Magenta

    # Script 17
    Write-Host "`n[Run $run] Script 17 - Security Hole Matrix" -ForegroundColor Yellow
    $out17 = powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR\17-security-hole-matrix.ps1" 2>&1
    $holes = Parse-Script17 -Lines $out17
    foreach ($order in @("D1","D2","D3")) {
        $val = $holes[$order]
        if ($null -ne $val) {
            $data["hole_$order"].Add($val)
            Add-Content -Path $RAW_CSV -Value "$run,script17,hole_$order,$val" -Encoding UTF8
            Write-Host ("  [17] $order hole = {0}s" -f $val)
        } else {
            Write-Host "  [17] WARNING: $order not parsed" -ForegroundColor Red
        }
    }

    # Script 18
    Write-Host "`n[Run $run] Script 18 - Policy Propagation Gap" -ForegroundColor Yellow
    $out18 = powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR\18-readiness-probe-vs-hstp.ps1" 2>&1
    $gaps = Parse-Script18 -Lines $out18
    $data["deny_gap"].Add($gaps.deny)
    $data["allow_gap"].Add($gaps.allow)
    Add-Content -Path $RAW_CSV -Value "$run,script18,deny_gap,$($gaps.deny)"   -Encoding UTF8
    Add-Content -Path $RAW_CSV -Value "$run,script18,allow_gap,$($gaps.allow)" -Encoding UTF8
    Write-Host ("  [18] DENY gap={0}s  ALLOW gap={1}s" -f $gaps.deny, $gaps.allow)

    # Script 15
    Write-Host "`n[Run $run] Script 15 - 3-Scenario Comparison" -ForegroundColor Yellow
    powershell.exe -ExecutionPolicy Bypass -File "$SCRIPT_DIR\15-compare-scenarios.ps1" 2>&1 | Out-Null
    $csv15 = Get-LatestCsv -Pattern "week6-comparison-*.csv"
    if ($csv15) {
        $rows = Import-Csv $csv15
        foreach ($row in $rows) {
            switch ($row.scenario) {
                "no_policy" {
                    $v = [double]$row.security_hole_sec
                    $b = [double]$row.lateral_block_rate_pct
                    $r = [double]$row.request_success_rate_pct
                    $data["np_hole"].Add($v)
                    $data["np_block"].Add($b)
                    $data["np_success"].Add($r)
                    Add-Content -Path $RAW_CSV -Value "$run,script15,np_hole,$v"    -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,np_block,$b"   -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,np_success,$r" -Encoding UTF8
                }
                "hstp_only" {
                    $b = [double]$row.lateral_block_rate_pct
                    $r = [double]$row.request_success_rate_pct
                    $w = [double]$row.transition_risk_window_sec
                    $data["h_block"].Add($b)
                    $data["h_success"].Add($r)
                    $data["h_risk"].Add($w)
                    Add-Content -Path $RAW_CSV -Value "$run,script15,h_block,$b"   -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,h_success,$r" -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,h_risk,$w"    -Encoding UTF8
                }
                "hstp_microseg" {
                    $b = [double]$row.lateral_block_rate_pct
                    $r = [double]$row.request_success_rate_pct
                    $w = [double]$row.transition_risk_window_sec
                    $data["hm_block"].Add($b)
                    $data["hm_success"].Add($r)
                    $data["hm_risk"].Add($w)
                    Add-Content -Path $RAW_CSV -Value "$run,script15,hm_block,$b"   -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,hm_success,$r" -Encoding UTF8
                    Add-Content -Path $RAW_CSV -Value "$run,script15,hm_risk,$w"    -Encoding UTF8
                }
            }
        }
        Write-Host "  [15] OK: $csv15"
    } else {
        Write-Host "  [15] WARNING: CSV not found" -ForegroundColor Red
    }

    if ($run -lt $Runs) {
        Write-Host "`n  Stabilizing 15s before next run..." -ForegroundColor Gray
        Start-Sleep -Seconds 15
    }
}

# Stats output
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  STATISTICAL SUMMARY  (N=$Runs runs)"           -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Set-Content -Path $STATS_CSV -Value "metric,n,mean,std,min,max,formatted" -Encoding UTF8

function Print-Stat {
    param([string]$Label, [string]$Key, [string]$Unit = "")
    $s = Calc-Stats -Values $data[$Key]
    $fmt = "{0} +/- {1}{2}" -f $s.mean, $s.std, $Unit
    Write-Host ("  {0,-45} {1}" -f $Label, $fmt)
    Add-Content -Path $STATS_CSV -Value "$Key,$($s.n),$($s.mean),$($s.std),$($s.min),$($s.max),$fmt" -Encoding UTF8
}

Write-Host ""
Write-Host "  [Script 17] Security Hole Duration" -ForegroundColor Yellow
Print-Stat "D1 (downstream-first) hole"  "hole_D1" "s"
Print-Stat "D2 (upstream-first)   hole"  "hole_D2" "s"
Print-Stat "D3 (mixed)            hole"  "hole_D3" "s"

Write-Host ""
Write-Host "  [Script 18] Policy Propagation Gap" -ForegroundColor Yellow
Print-Stat "DENY  propagation gap"  "deny_gap"  "s"
Print-Stat "ALLOW propagation gap"  "allow_gap" "s"

Write-Host ""
Write-Host "  [Script 15] Scenario Comparison" -ForegroundColor Yellow
Write-Host "  -- No-Policy --" -ForegroundColor Red
Print-Stat "  Security hole"          "np_hole"    "s"
Print-Stat "  Lateral block rate"     "np_block"   "%"
Print-Stat "  Request success rate"   "np_success" "%"
Write-Host "  -- HSTP only --" -ForegroundColor Yellow
Print-Stat "  Lateral block rate"     "h_block"    "%"
Print-Stat "  Request success rate"   "h_success"  "%"
Print-Stat "  Transition risk window" "h_risk"     "s"
Write-Host "  -- HSTP + Microseg --" -ForegroundColor Green
Print-Stat "  Lateral block rate"     "hm_block"   "%"
Print-Stat "  Request success rate"   "hm_success" "%"
Print-Stat "  Transition risk window" "hm_risk"    "s"

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Raw data : $RAW_CSV"
Write-Host "  Stats CSV: $STATS_CSV"
Write-Host "  Next     : .\16-generate-report.ps1"
Write-Host "=================================================" -ForegroundColor Cyan
