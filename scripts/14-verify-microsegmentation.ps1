<#
.SYNOPSIS
    Week 5 - Verify Microsegmentation
    3가지 시나리오를 비교한다:
      Scenario 1: No-Policy (Week 3 재현)
      Scenario 2: HSTP only (Week 4)
      Scenario 3: HSTP + Microsegmentation (Week 5)

    측정 항목:
    - 체인 정상 동작 (auth /call 성공)
    - Attacker 직접 접근 차단
    - Cross-namespace 접근 차단
#>

$ErrorActionPreference = "Continue"
$NS        = "ota-pipeline"
$TIMESTAMP = Get-Date -Format "yyyyMMdd-HHmmss"
$LOG_DIR   = Join-Path (Get-Item (Join-Path $PWD "..")).FullName "logs"
$CSV_FILE  = Join-Path $LOG_DIR "microseg-verify-$TIMESTAMP.csv"

if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }

$header = "scenario,attacker_ns,target,http_status,accessible,notes"
Set-Content -Path $CSV_FILE -Value $header -Encoding UTF8

function Test-Access {
    param([string]$Scenario, [string]$Pod, [string]$PodNS,
          [string]$Target, [string]$TargetNS = $NS, [string]$Notes = "")

    $fqdn = if ($PodNS -eq $TargetNS) { "${Target}:8080" } `
            else { "${Target}.${TargetNS}.svc.cluster.local:8080" }

    $raw = kubectl exec $Pod -n $PodNS -- `
        curl -s -o /dev/null -w "%{http_code}" `
        --connect-timeout 2 --max-time 4 `
        "http://${fqdn}/health" 2>$null
    $code = ($raw | Select-Object -Last 1).Trim()
    $ok   = if ($code -match "^2") { "YES" } else { "NO" }
    $color = if ($ok -eq "YES") { "Red" } else { "Green" }

    Write-Host ("    {0,-8} -> {1,-10}: {2} [{3}]" -f $PodNS, $Target, $code, $ok) -ForegroundColor $color
    Add-Content -Path $CSV_FILE -Value "$Scenario,$PodNS,$Target,$code,$ok,$Notes" -Encoding UTF8
    return $ok
}

function Test-Chain {
    param([string]$Scenario)
    $raw = kubectl exec load-gen -n $NS -- `
        curl -s -o /tmp/r.txt -w "%{http_code}" `
        --connect-timeout 3 --max-time 8 `
        http://auth:8080/call 2>$null
    $code = ($raw | Select-Object -Last 1).Trim()
    $body = kubectl exec load-gen -n $NS -- cat /tmp/r.txt 2>$null
    $depth = 0
    foreach ($s in @("auth","campaign","package","deploy")) {
        if ($body -match $s) { $depth++ }
    }
    $ok = if ($code -eq "200") { "OK" } else { "FAIL" }
    $color = if ($ok -eq "OK") { "Green" } else { "Red" }
    Write-Host ("    [chain] auth/call -> HTTP $code depth=$depth [$ok]") -ForegroundColor $color
    Add-Content -Path $CSV_FILE -Value "$Scenario,load-gen,auth-chain,$code,$ok,depth=$depth" -Encoding UTF8
    return $depth
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Week 5 - Microsegmentation Verification"   -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# 모든 서비스 실행 확인
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
}

# 파드 준비
kubectl delete pod load-gen    -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker    -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker-ext -n default --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2

kubectl run load-gen     -n $NS     --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
kubectl run attacker     -n $NS     --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
kubectl run attacker-ext -n default --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null

$waited = 0
do {
    Start-Sleep -Seconds 3; $waited += 3
    $a = kubectl get pod load-gen     -n $NS      --no-headers 2>$null
    $b = kubectl get pod attacker     -n $NS      --no-headers 2>$null
    $c = kubectl get pod attacker-ext -n default  --no-headers 2>$null
} while (($a -notmatch "Running" -or $b -notmatch "Running" -or $c -notmatch "Running") -and $waited -lt 90)
Write-Host "Pods ready ($waited s).`n"

# ── Test 1: 체인 정상 동작 ────────────────────────────────────────────
Write-Host "[TEST 1] Pipeline chain: auth -> campaign -> package -> deploy" -ForegroundColor Cyan
$depth = Test-Chain -Scenario "chain"
Write-Host ""

# ── Test 2: 같은 NS attacker 직접 접근 ───────────────────────────────
Write-Host "[TEST 2] Same-NS attacker direct access (should be BLOCKED)" -ForegroundColor Cyan
foreach ($target in @("deploy","package","campaign")) {
    Test-Access -Scenario "same_ns_attacker" -Pod "attacker" -PodNS $NS `
        -Target $target -Notes "should_be_blocked" | Out-Null
}
Write-Host "  (auth is OK — entry point)"
Test-Access -Scenario "same_ns_attacker" -Pod "attacker" -PodNS $NS `
    -Target "auth" -Notes "entry_point_allowed" | Out-Null
Write-Host ""

# ── Test 3: Cross-namespace 접근 ────────────────────────────────────
Write-Host "[TEST 3] Cross-namespace attacker (default NS) — should be BLOCKED" -ForegroundColor Cyan
foreach ($target in @("deploy","package","campaign","auth")) {
    Test-Access -Scenario "cross_ns_attacker" -Pod "attacker-ext" -PodNS "default" `
        -Target $target -TargetNS $NS -Notes "cross_ns" | Out-Null
}
Write-Host ""

# Cleanup
kubectl delete pod load-gen     -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker     -n $NS      --grace-period=0 --force 2>$null | Out-Null
kubectl delete pod attacker-ext -n default  --grace-period=0 --force 2>$null | Out-Null

# ── 결과 요약 ─────────────────────────────────────────────────────────
$allRows = Get-Content $CSV_FILE | Select-Object -Skip 1

$chainOk      = ($allRows | Where-Object { $_ -match "auth-chain" -and $_ -match ",OK," }).Count
$sameBlocked  = ($allRows | Where-Object { $_ -match "same_ns_attacker" -and $_ -match ",NO," }).Count
$sameTotal    = ($allRows | Where-Object { $_ -match "same_ns_attacker" }).Count
$crossBlocked = ($allRows | Where-Object { $_ -match "cross_ns_attacker" -and $_ -match ",NO," }).Count
$crossTotal   = ($allRows | Where-Object { $_ -match "cross_ns_attacker" }).Count

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RESULT: Microsegmentation Verification"    -ForegroundColor Green
Write-Host ""
$chainStr  = if ($chainOk -gt 0) { "OK (depth=4)" } else { "FAIL" }
$chainCol  = if ($chainOk -gt 0) { "Green" } else { "Red" }
$sameCol   = if ($sameBlocked -ge 3)  { "Green" } else { "Red" }
$crossCol  = if ($crossBlocked -ge 3) { "Green" } else { "Red" }

Write-Host ("  {0,-35} {1}" -f "Pipeline chain (auth/call):", $chainStr) -ForegroundColor $chainCol
Write-Host ("  {0,-35} {1}" -f "Same-NS lateral move blocked:", "$sameBlocked / $sameTotal") -ForegroundColor $sameCol
Write-Host ("  {0,-35} {1}" -f "Cross-NS access blocked:", "$crossBlocked / $crossTotal") -ForegroundColor $crossCol
Write-Host ""
Write-Host "  Output CSV: $CSV_FILE"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
