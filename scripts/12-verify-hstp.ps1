<#
.SYNOPSIS
    Week 4 - Verify HSTP vs No-Policy Comparison
    HSTP 적용 전후 lateral movement 차단 효과를 비교한다.

    1. 모든 서비스 실행 + HSTP deny policy 없는 상태 -> baseline (Week 3 재현)
    2. HSTP deactivation 실행 -> deny policy 적용
    3. 동일한 attacker 시도 -> 차단 여부 확인

.EXAMPLE
    .\12-verify-hstp.ps1
#>

$ErrorActionPreference = "Continue"
$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$CSV_FILE  = Join-Path $LOG_DIR "hstp-verify-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

$header = "scenario,attacker_ns,target,endpoint,http_status,response_time_ms,accessible,policy_applied"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

function Test-Access {
    param([string]$Scenario, [string]$AttackerPod, [string]$AttackerNS,
          [string]$Target, [string]$TargetNS, [string]$PolicyApplied)
    $ep = "/health"
    $fqdn = if ($AttackerNS -eq $TargetNS) { "${Target}:8080" } else { "${Target}.${TargetNS}.svc.cluster.local:8080" }

    $t0 = Get-Date
    $raw = kubectl exec $AttackerPod -n $AttackerNS -- `
        curl -s -o /dev/null -w "%{http_code}" `
        --connect-timeout 2 --max-time 4 `
        "http://${fqdn}${ep}" 2>$null
    $code   = ($raw | Select-Object -Last 1).Trim()
    $respMs = [int]((Get-Date) - $t0).TotalMilliseconds
    $accessible = if ($code -match "^2") { "YES" } else { "NO" }
    $color = if ($accessible -eq "YES" -and $PolicyApplied -eq "yes") { "Red" } `
             elseif ($accessible -eq "YES") { "Yellow" } else { "Green" }

    Write-Host ("  [{0}] {1,-8} -> {2,-10}: HTTP {3} [{4}]" -f `
        $Scenario, $AttackerNS, $Target, $code, $accessible) -ForegroundColor $color

    Add-Content -Path $CSV_FILE -Value "$Scenario,$AttackerNS,$Target,$ep,$code,$respMs,$accessible,$PolicyApplied" -Encoding UTF8
    return $accessible
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 4 - HSTP Verification"               -ForegroundColor Cyan
Write-Host "  Comparing: no-policy vs HSTP"              -ForegroundColor Yellow
Write-Host "  CSV -> $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Phase A: 모든 서비스 UP + 정책 없음 (Week 3 baseline 재현) ─────
Write-Host "[PHASE A] No-policy baseline (all services up)..."
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl delete authorizationpolicy "hstp-deny-$svc" -n $NS 2>$null | Out-Null
}

# attacker pods 배포
kubectl delete pod attacker     -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker-ext -n default  --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run attacker     -n $NS     --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
kubectl run attacker-ext -n default --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $a = kubectl get pod attacker -n $NS --no-headers 2>$null
    $b = kubectl get pod attacker-ext -n default --no-headers 2>$null
} while (($a -notmatch "Running" -or $b -notmatch "Running") -and $waited -lt 60)
Write-Host ""

$noPolicyResults = @{}
foreach ($target in @("deploy","package","campaign","auth")) {
    $r = Test-Access -Scenario "A_no_policy" -AttackerPod "attacker" -AttackerNS $NS `
             -Target $target -TargetNS $NS -PolicyApplied "no"
    $noPolicyResults[$target] = $r
}
foreach ($target in @("deploy","package")) {
    Test-Access -Scenario "A_cross_ns" -AttackerPod "attacker-ext" -AttackerNS "default" `
        -Target $target -TargetNS $NS -PolicyApplied "no" | Out-Null
}
Write-Host ""

# ── Phase B: HSTP deactivation (D1 safe order) ───────────────────────
Write-Host "[PHASE B] Running HSTP safe deactivation..."
$verifyWaveName = "hstp-verify-$TIMESTAMP"
kubectl delete otawave $verifyWaveName -n $NS 2>$null | Out-Null
Start-Sleep -Seconds 2

$waveYaml = @"
apiVersion: ota.research/v1
kind: OTAWave
metadata:
  name: $verifyWaveName
  namespace: $NS
spec:
  action: deactivate
  order:
    - deploy
    - package
    - campaign
    - auth
  drainSeconds: 5
"@
$waveYaml | kubectl apply -f - 2>&1 | Out-Null
Write-Host "  OTAWave submitted. Waiting for completion..."

$waited = 0
do {
    Start-Sleep -Seconds 5; $waited += 5
    $phase = kubectl get otawave $verifyWaveName -n $NS -o jsonpath='{.status.phase}' 2>$null
    $step  = kubectl get otawave $verifyWaveName -n $NS -o jsonpath='{.status.currentStep}' 2>$null
    Write-Host "  [$waited s] Wave phase=$phase step=$step"
} while ($phase -notin @("Completed","Failed") -and $waited -lt 240)

Write-Host "  Wave completed: $phase`n"

# ── Phase C: HSTP 적용 후 동일한 공격 시도 ───────────────────────────
Write-Host "[PHASE C] Repeating lateral movement test AFTER HSTP..."
Write-Host ""

$hstpResults = @{}
foreach ($target in @("deploy","package","campaign","auth")) {
    $r = Test-Access -Scenario "C_after_hstp" -AttackerPod "attacker" -AttackerNS $NS `
             -Target $target -TargetNS $NS -PolicyApplied "yes"
    $hstpResults[$target] = $r
}
foreach ($target in @("deploy","package")) {
    Test-Access -Scenario "C_cross_ns" -AttackerPod "attacker-ext" -AttackerNS "default" `
        -Target $target -TargetNS $NS -PolicyApplied "yes" | Out-Null
}

# Cleanup
kubectl delete pod attacker     -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker-ext -n default  --grace-period=0 --force 2>$null | Out-Null

# ── 비교 요약 ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  COMPARISON: No-Policy vs HSTP"             -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ("  {0,-12} {1,-12} {2,-12}" -f "Service","No-Policy","After-HSTP")
Write-Host ("  {0,-12} {1,-12} {2,-12}" -f "-------","---------","----------")
foreach ($svc in @("deploy","package","campaign","auth")) {
    $before = $noPolicyResults[$svc]
    $after  = $hstpResults[$svc]
    $beforeColor = if ($before -eq "YES") { "Red" } else { "Green" }
    $afterColor  = if ($after  -eq "YES") { "Red" } else { "Green" }
    Write-Host ("  {0,-12}" -f $svc) -NoNewline
    Write-Host ("{0,-12}" -f $before) -NoNewline -ForegroundColor $beforeColor
    Write-Host ("{0,-12}" -f $after)              -ForegroundColor $afterColor
}
Write-Host ""
$allRows     = Get-Content $CSV_FILE | Select-Object -Skip 1
$blockedPost = ($allRows | Where-Object { $_ -match "C_after_hstp" -and $_ -match ",NO," }).Count
$totalPost   = ($allRows | Where-Object { $_ -match "C_after_hstp" }).Count
Write-Host "  Post-HSTP blocked: $blockedPost / $totalPost" -ForegroundColor Green
Write-Host "  Output CSV: $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
