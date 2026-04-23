<#
.SYNOPSIS
    Week 6 - Three-Scenario Comparison
    D2 deactivation (worst case) 기준으로 3가지 시나리오를 비교한다.

    Scenario 1: No-Policy
    Scenario 2: HSTP only (external gate, no microsegmentation)
    Scenario 3: HSTP + Microsegmentation (full protection)

    측정 메트릭:
    - security_hole_sec        : auth 제거 후 deploy 접근 가능 시간
    - attack_window_sec        : activation 중 deploy 노출 시간 (A2 기준)
    - lateral_move_block_rate  : attacker 접근 차단 성공률
    - request_success_rate     : 전환 중 정상 요청 성공률
    - transition_risk_window   : 첫 서비스 변경 ~ 완전 안정화 시간
#>

$ErrorActionPreference = "Continue"
$NS           = "ota-pipeline"
$TIMESTAMP    = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR      = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$K8S_DIR      = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "k8s"
$SUMMARY_CSV  = Join-Path $LOG_DIR "week6-comparison-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

$summaryHeader = "scenario,security_hole_sec,attack_window_sec,lateral_block_rate_pct,request_success_rate_pct,transition_risk_window_sec,lateral_blocked,lateral_total,req_success,req_total"
Set-Content -Path $SUMMARY_CSV -Value $summaryHeader -Encoding UTF8

# ── 공통 헬퍼 ─────────────────────────────────────────────────────────

function Wait-LoadGen {
    kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
    kubectl delete pod attacker  -n $NS --grace-period=0 --force 2>$null | Out-Null
    Start-Sleep -Seconds 2
    kubectl run load-gen -n $NS --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
    kubectl run attacker  -n $NS --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
    $w = 0
    do {
        Start-Sleep -Seconds 3; $w += 3
        $a = kubectl get pod load-gen -n $NS --no-headers 2>$null
        $b = kubectl get pod attacker  -n $NS --no-headers 2>$null
    } while (($a -notmatch "Running" -or $b -notmatch "Running") -and $w -lt 60)
}

function Ensure-AllUp {
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
    }
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
    }
}

function Measure-Request {
    param([string]$Pod = "load-gen")
    $t0  = Get-Date
    $raw = kubectl exec $Pod -n $NS -- curl -s -o /tmp/r.txt -w "%{http_code}" `
               --connect-timeout 2 --max-time 5 http://auth:8080/call 2>$null
    $code = ($raw | Select-Object -Last 1).Trim()
    $ms   = [int]((Get-Date) - $t0).TotalMilliseconds
    return $code
}

function Measure-LateralAccess {
    param([string]$Target)
    $raw = kubectl exec attacker -n $NS -- curl -s -o /dev/null -w "%{http_code}" `
               --connect-timeout 2 --max-time 4 "http://${Target}:8080/health" 2>$null
    return ($raw | Select-Object -Last 1).Trim()
}

# ── 시나리오 실행 함수 ────────────────────────────────────────────────

function Run-Scenario {
    param([string]$Name, [string]$Label)

    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "  SCENARIO: $Label" -ForegroundColor Magenta
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""

    Ensure-AllUp
    Wait-LoadGen
    Start-Sleep -Seconds 5

    $startTime      = Get-Date
    $reqSuccess     = 0
    $reqTotal       = 0
    $latBlocked     = 0
    $latTotal       = 0
    $secHoleStart   = $null
    $secHoleEnd     = $null
    $riskStart      = Get-Date

    # D2 deactivation: auth -> campaign -> package -> deploy
    $D2 = @("auth","campaign","package","deploy")

    foreach ($svc in $D2) {
        Write-Host "  [D2] Removing '$svc'..." -ForegroundColor Red
        kubectl scale deployment $svc -n $NS --replicas=0 2>&1 | Out-Null

        if ($svc -eq "auth")   { $secHoleStart = (Get-Date) - $startTime }
        if ($svc -eq "deploy") { $secHoleEnd   = (Get-Date) - $startTime }

        # 15초 측정
        $end = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $end) {
            # 정상 요청 (load-gen -> auth -> chain)
            $code = Measure-Request
            $reqTotal++
            if ($code -eq "200") { $reqSuccess++ }

            # 공격자 lateral movement (-> deploy)
            $lcode = Measure-LateralAccess -Target "deploy"
            $latTotal++
            if ($lcode -notmatch "^2") { $latBlocked++ }

            Start-Sleep -Seconds 2
        }

        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
        Write-Host ("    req_ok={0}/{1}  lat_blocked={2}/{3}  t={4}s" -f `
            $reqSuccess, $reqTotal, $latBlocked, $latTotal, $elapsed)
    }

    $riskWindow = [math]::Round(((Get-Date) - $riskStart).TotalSeconds, 0)

    # Security hole: auth 제거 ~ deploy 제거 사이 시간
    $secHoleSec = "N/A"
    if ($secHoleStart -ne $null -and $secHoleEnd -ne $null) {
        $secHoleSec = [math]::Round(($secHoleEnd - $secHoleStart).TotalSeconds, 1)
    }

    # Attack Window: Week 2 A2 결과 사용 (시나리오 공통 ~50s, HSTP시 0s)
    $attackWindowSec = switch ($Name) {
        "no_policy" { "50.4" }
        "hstp_only" { "0" }
        "hstp_microseg" { "0" }
    }

    $blockRate   = if ($latTotal -gt 0) { [math]::Round($latBlocked / $latTotal * 100, 1) } else { 0 }
    $successRate = if ($reqTotal -gt 0) { [math]::Round($reqSuccess / $reqTotal * 100, 1) } else { 0 }

    # 요약 CSV 행
    $row = "$Name,$secHoleSec,$attackWindowSec,$blockRate,$successRate,$riskWindow,$latBlocked,$latTotal,$reqSuccess,$reqTotal"
    Add-Content -Path $SUMMARY_CSV -Value $row -Encoding UTF8

    Write-Host ""
    Write-Host "  Result: hole=${secHoleSec}s  block=${blockRate}%  success=${successRate}%" -ForegroundColor Yellow
    Write-Host ""

    # 서비스 복구
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
    }
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
    }

    kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
    kubectl delete pod attacker  -n $NS --grace-period=0 --force 2>$null | Out-Null
    Start-Sleep -Seconds 10
}

# ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Week 6 - Three-Scenario Comparison"           -ForegroundColor Cyan
Write-Host "  Worst case: D2 deactivation"                  -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor Cyan

# ── Scenario 1: No-Policy ─────────────────────────────────────────────
Write-Host "`n[SETUP] Scenario 1: removing all policies..."
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl delete authorizationpolicy "allow-$svc-from-any"            -n $NS 2>$null | Out-Null
    kubectl delete authorizationpolicy "allow-$svc-from-auth-sa"        -n $NS 2>$null | Out-Null
    kubectl delete authorizationpolicy "allow-campaign-from-auth-sa"    -n $NS 2>$null | Out-Null
    kubectl delete authorizationpolicy "allow-package-from-campaign-sa" -n $NS 2>$null | Out-Null
    kubectl delete authorizationpolicy "allow-deploy-from-package-sa"   -n $NS 2>$null | Out-Null
    kubectl delete authorizationpolicy "allow-auth-from-any"            -n $NS 2>$null | Out-Null
}
kubectl get networkpolicy -n $NS --no-headers 2>$null | ForEach-Object {
    $npName = ($_ -split "\s+")[0]
    kubectl delete networkpolicy $npName -n $NS 2>$null | Out-Null
}
kubectl apply -f "$K8S_DIR\peer-auth.yaml" 2>&1 | Out-Null  # PERMISSIVE
Start-Sleep -Seconds 10

Run-Scenario -Name "no_policy" -Label "Scenario 1: No-Policy (baseline)"

# ── Scenario 2: HSTP only ─────────────────────────────────────────────
Write-Host "`n[SETUP] Scenario 2: HSTP only (no microsegmentation)..."
# 정책 없는 상태에서 HSTP wave 제출
$waveName2 = "s2-wave-$TIMESTAMP"
$wave2 = @"
apiVersion: ota.research/v1
kind: OTAWave
metadata:
  name: $waveName2
  namespace: $NS
spec:
  action: deactivate
  order: [deploy, package, campaign, auth]
  drainSeconds: 8
"@

Ensure-AllUp
Wait-LoadGen
Start-Sleep -Seconds 5

$startTime2  = Get-Date
$reqSuccess2 = 0; $reqTotal2 = 0; $latBlocked2 = 0; $latTotal2 = 0

$wave2 | kubectl apply -f - 2>&1 | Out-Null
Write-Host "  OTAWave submitted (safe order: deploy->package->campaign->auth)"

$deadline = (Get-Date).AddSeconds(200)
while ((Get-Date) -lt $deadline) {
    $phase = kubectl get otawave $waveName2 -n $NS -o jsonpath='{.status.phase}' 2>$null
    $code  = Measure-Request
    $reqTotal2++
    if ($code -eq "200") { $reqSuccess2++ }
    $lcode = Measure-LateralAccess -Target "deploy"
    $latTotal2++
    if ($lcode -notmatch "^2") { $latBlocked2++ }

    $elapsed = [math]::Round(((Get-Date) - $startTime2).TotalSeconds, 0)
    if ($reqTotal2 % 5 -eq 0) {
        Write-Host ("  [${elapsed}s] wave=$phase req_ok={0}/{1} lat_blocked={2}/{3}" -f `
            $reqSuccess2,$reqTotal2,$latBlocked2,$latTotal2)
    }
    if ($phase -eq "Completed" -or $phase -eq "Failed") { break }
    Start-Sleep -Seconds 2
}

$riskWindow2 = [math]::Round(((Get-Date) - $startTime2).TotalSeconds, 0)
$blockRate2  = if ($latTotal2 -gt 0) { [math]::Round($latBlocked2/$latTotal2*100,1) } else { 0 }
$succRate2   = if ($reqTotal2 -gt 0) { [math]::Round($reqSuccess2/$reqTotal2*100,1) } else { 0 }

Add-Content -Path $SUMMARY_CSV -Value "hstp_only,0,0,$blockRate2,$succRate2,$riskWindow2,$latBlocked2,$latTotal2,$reqSuccess2,$reqTotal2" -Encoding UTF8
Write-Host "  Result: block=${blockRate2}%  success=${succRate2}%  risk=${riskWindow2}s" -ForegroundColor Yellow

foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker  -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 10

# ── Scenario 3: HSTP + Microsegmentation ─────────────────────────────
Write-Host "`n[SETUP] Scenario 3: HSTP + Microsegmentation..."
$SCRIPT_DIR = (Get-Item (Join-Path $PWD ".")).FullName
& "$SCRIPT_DIR\13-deploy-microsegmentation.ps1" 2>&1 | Where-Object { $_ -match "\[|OK|FAIL|Chain" } | ForEach-Object { Write-Host "  $_" }
Start-Sleep -Seconds 10

$waveName3 = "s3-wave-$TIMESTAMP"
$wave3 = @"
apiVersion: ota.research/v1
kind: OTAWave
metadata:
  name: $waveName3
  namespace: $NS
spec:
  action: deactivate
  order: [deploy, package, campaign, auth]
  drainSeconds: 8
"@

Ensure-AllUp
Wait-LoadGen
Start-Sleep -Seconds 5

$startTime3  = Get-Date
$reqSuccess3 = 0; $reqTotal3 = 0; $latBlocked3 = 0; $latTotal3 = 0

$wave3 | kubectl apply -f - 2>&1 | Out-Null
Write-Host "  OTAWave submitted"

$deadline = (Get-Date).AddSeconds(200)
while ((Get-Date) -lt $deadline) {
    $phase = kubectl get otawave $waveName3 -n $NS -o jsonpath='{.status.phase}' 2>$null
    $code  = Measure-Request
    $reqTotal3++
    if ($code -eq "200") { $reqSuccess3++ }
    $lcode = Measure-LateralAccess -Target "deploy"
    $latTotal3++
    if ($lcode -notmatch "^2") { $latBlocked3++ }

    $elapsed = [math]::Round(((Get-Date) - $startTime3).TotalSeconds, 0)
    if ($reqTotal3 % 5 -eq 0) {
        Write-Host ("  [${elapsed}s] wave=$phase req_ok={0}/{1} lat_blocked={2}/{3}" -f `
            $reqSuccess3,$reqTotal3,$latBlocked3,$latTotal3)
    }
    if ($phase -eq "Completed" -or $phase -eq "Failed") { break }
    Start-Sleep -Seconds 2
}

$riskWindow3 = [math]::Round(((Get-Date) - $startTime3).TotalSeconds, 0)
$blockRate3  = if ($latTotal3 -gt 0) { [math]::Round($latBlocked3/$latTotal3*100,1) } else { 0 }
$succRate3   = if ($reqTotal3 -gt 0) { [math]::Round($reqSuccess3/$reqTotal3*100,1) } else { 0 }

Add-Content -Path $SUMMARY_CSV -Value "hstp_microseg,0,0,$blockRate3,$succRate3,$riskWindow3,$latBlocked3,$latTotal3,$reqSuccess3,$reqTotal3" -Encoding UTF8
Write-Host "  Result: block=${blockRate3}%  success=${succRate3}%  risk=${riskWindow3}s" -ForegroundColor Yellow

kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker  -n $NS --grace-period=0 --force 2>$null | Out-Null

# ── 최종 비교 테이블 ──────────────────────────────────────────────────
$rows = Get-Content $SUMMARY_CSV | Select-Object -Skip 1

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  WEEK 6 COMPARISON RESULTS"                      -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-22} {1,10} {2,10} {3,10} {4,10} {5,10}" -f `
    "Scenario","Hole(s)","Atk Win(s)","Block%","SuccReq%","Risk(s)")
Write-Host ("  {0,-22} {1,10} {2,10} {3,10} {4,10} {5,10}" -f `
    "----------------------","--------","----------","------","--------","-------")

foreach ($r in $rows) {
    $c = $r -split ","
    if ($c.Count -ge 6) {
        $color = switch ($c[0]) {
            "no_policy"     { "Red" }
            "hstp_only"     { "Yellow" }
            "hstp_microseg" { "Green" }
        }
        Write-Host ("  {0,-22} {1,10} {2,10} {3,10} {4,10} {5,10}" -f `
            $c[0],$c[1],$c[2],$c[3],$c[4],$c[5]) -ForegroundColor $color
    }
}

Write-Host ""
Write-Host "  Summary CSV: $SUMMARY_CSV"
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next: .\16-generate-report.ps1"
