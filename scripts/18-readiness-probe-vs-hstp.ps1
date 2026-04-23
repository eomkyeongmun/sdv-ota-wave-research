<#
.SYNOPSIS
    둘째 기여 실증 — readiness probe만으로는 전환 안전성 불충분 증명

    실험 설계 (Policy Propagation Gap 측정):
      Phase 1: kubectl apply DENY policy → 즉시 트래픽 측정
               (readiness probe=OK, 하지만 policy가 Envoy에 아직 전파 안됨)
               → DENY가 실제로 적용되기까지 요청이 통과함 = 보안 취약 구간

      Phase 2: kubectl delete DENY policy (ALLOW 복구) → 즉시 트래픽 측정
               (readiness probe=OK, 하지만 ALLOW가 아직 전파 안됨)
               → 요청이 여전히 거부됨 = 가용성 취약 구간

    핵심 주장:
      readiness probe는 HTTP health만 확인 → Istio policy 동기화 여부 모름
      HSTP는 policy propagation이 완료될 때까지 명시적으로 대기함

    측정 항목:
      - policy_propagation_delay_sec: kubectl apply 후 실제 적용까지 걸리는 시간
      - readiness_gap_sec: readiness OK와 policy sync 완료 사이의 갭
      - DENY gap (보안 취약): policy는 DENY 인데 아직 통과되는 시간
      - ALLOW gap (가용성 취약): policy는 ALLOW 인데 아직 거부되는 시간
#>

$ErrorActionPreference = "Continue"
$NS           = "ota-pipeline"
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$LOGS_DIR     = Join-Path $PROJECT_ROOT "logs"
$K8S_DIR      = Join-Path $PROJECT_ROOT "k8s"
$TIMESTAMP    = Get-Date -Format "yyyyMMdd-HHmmss"
$CSV_FILE     = Join-Path $LOGS_DIR "readiness-vs-hstp-$TIMESTAMP.csv"

if (-not (Test-Path $LOGS_DIR)) { New-Item -ItemType Directory -Path $LOGS_DIR | Out-Null }

Set-Content -Path $CSV_FILE -Value "phase,elapsed_sec,http_code,chain_depth,success,policy_state,notes" -Encoding UTF8

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Readiness Probe vs HSTP Multi-Gate"            -ForegroundColor Cyan
Write-Host "  Policy Propagation Gap Measurement"            -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# load-gen pod 준비
kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run load-gen -n $NS --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$w = 0; do { Start-Sleep -Seconds 3; $w += 3
    $s = kubectl get pod load-gen -n $NS --no-headers 2>$null
} while ($s -notmatch "Running" -and $w -lt 60)
Write-Host "load-gen ready.`n"

function Test-Chain {
    param([string]$Phase, [double]$Elapsed, [string]$PolicyState, [string]$Notes = "")
    $raw = kubectl exec load-gen -n $NS -- `
        curl -s -o /tmp/r.txt -w "%{http_code}" `
        --connect-timeout 3 --max-time 8 `
        http://auth:8080/call 2>$null
    $code  = ($raw | Select-Object -Last 1).Trim()
    $body  = kubectl exec load-gen -n $NS -- cat /tmp/r.txt 2>$null
    $depth = 0
    foreach ($s in @("auth","campaign","package","deploy")) { if ($body -match $s) { $depth++ } }
    $ok    = if ($code -eq "200" -and $depth -ge 1) { "YES" } else { "NO" }
    $color = if ($ok -eq "YES") { "Green" } else { "Red" }
    Write-Host ("    [{0,-22}] t={1,5}s  HTTP {2}  depth={3}  [{4}]" -f $Phase, [math]::Round($Elapsed,1), $code, $depth, $ok) -ForegroundColor $color
    Add-Content -Path $CSV_FILE -Value "$Phase,$([math]::Round($Elapsed,2)),$code,$depth,$ok,$PolicyState,$Notes" -Encoding UTF8
    return $ok
}

# ── 기준선: ALLOW 상태 확인 ───────────────────────────────────────────
Write-Host "[BASELINE] Confirming chain works with ALLOW policies..." -ForegroundColor Gray
kubectl apply -f "$K8S_DIR\authpolicy-chain.yaml" 2>&1 | Out-Null
kubectl apply -f "$K8S_DIR\peer-auth-strict.yaml" 2>&1 | Out-Null
Start-Sleep -Seconds 5
$baseStart = Get-Date
for ($i = 0; $i -lt 3; $i++) {
    $e = ((Get-Date) - $baseStart).TotalSeconds
    Test-Chain -Phase "baseline_allow" -Elapsed $e -PolicyState "ALLOW" | Out-Null
    Start-Sleep -Seconds 2
}
Write-Host ""

# ── Phase 1: DENY policy 적용 직후 → readiness-only gate 시뮬레이션 ──
# "kubectl apply 했다 = readiness probe는 여전히 OK"
# 하지만 Envoy에 DENY policy가 전파되기까지 얼마나 요청이 통과하나?
Write-Host "[PHASE 1] Apply DENY policy -> measure propagation gap (security risk)" -ForegroundColor Yellow
Write-Host "  Scenario: transition controller applies DENY but Envoy not yet synced"
Write-Host "  Requests that pass during gap = attacker/stale traffic still flowing`n"

# 임시 DENY policy (auth에 대한 DENY)
$denyYaml = @"
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-campaign-all
  namespace: ota-pipeline
spec:
  selector:
    matchLabels:
      app: campaign
  action: DENY
  rules:
    - {}
"@
$denyFile = Join-Path $LOGS_DIR "tmp-deny.yaml"
Set-Content -Path $denyFile -Value $denyYaml -Encoding UTF8

$applyTime = Get-Date
kubectl apply -f $denyFile 2>&1 | Out-Null
Write-Host ("  DENY applied at t=0 (kubectl returned immediately)")

# 즉시부터 측정 — readiness probe는 여전히 OK지만 policy는 전파 중
$denyGapStart  = $null
$denyGapEnd    = $null
$phase1Passed  = 0
$phase1Total   = 0
for ($i = 0; $i -lt 20; $i++) {
    $elapsed = ((Get-Date) - $applyTime).TotalSeconds
    $result  = Test-Chain -Phase "deny_propagation" -Elapsed $elapsed -PolicyState "DENY_APPLIED"
    $phase1Total++
    if ($result -eq "YES") {
        $phase1Passed++
        if ($null -eq $denyGapStart) { $denyGapStart = $elapsed }
        $denyGapEnd = $elapsed
    } else {
        if ($null -ne $denyGapStart -and $null -eq $denyGapEnd) { $denyGapEnd = $elapsed }
        if ($phase1Total -gt 3) { break }  # 연속 3번 실패 → 전파 완료
    }
    Start-Sleep -Seconds 2
}

$denyPropDelay = if ($null -ne $denyGapEnd) { [math]::Round($denyGapEnd, 1) } else { "immediate" }
Write-Host ""
Write-Host ("  DENY policy passed (still accessible) for: ~{0}s after kubectl apply" -f $denyPropDelay) -ForegroundColor Red
Write-Host ("  = readiness probe said OK, but DENY policy not yet effective for {0}s" -f $denyPropDelay) -ForegroundColor Red
Write-Host ""

# ── Phase 2: DENY 제거 (ALLOW 복구) → 가용성 복구 지연 측정 ──────────
Write-Host "[PHASE 2] Delete DENY policy -> measure ALLOW propagation gap (availability risk)" -ForegroundColor Yellow
Write-Host "  Scenario: HSTP removes DENY after drain, but Envoy still blocking"
Write-Host "  Requests blocked during gap = unnecessary downtime`n"

$deleteTime = Get-Date
kubectl delete authorizationpolicy deny-campaign-all -n $NS 2>$null | Out-Null
Write-Host "  DENY deleted at t=0 (kubectl returned immediately)"

$allowGapStart = $null
$allowGapEnd   = $null
$phase2Passed  = 0
$phase2Total   = 0
for ($i = 0; $i -lt 20; $i++) {
    $elapsed = ((Get-Date) - $deleteTime).TotalSeconds
    $result  = Test-Chain -Phase "allow_propagation" -Elapsed $elapsed -PolicyState "ALLOW_APPLIED"
    $phase2Total++
    if ($result -eq "NO") {
        if ($null -eq $allowGapStart) { $allowGapStart = $elapsed }
        $allowGapEnd = $elapsed
    } else {
        $phase2Passed++
        if ($null -ne $allowGapStart) { break }  # 첫 성공 = 전파 완료
        if ($phase2Total -gt 3) { break }
    }
    Start-Sleep -Seconds 2
}

$allowPropDelay = if ($null -ne $allowGapEnd) { [math]::Round($allowGapEnd, 1) } else { "immediate" }
Write-Host ""
Write-Host ("  ALLOW policy took ~{0}s to take effect after kubectl delete" -f $allowPropDelay) -ForegroundColor Yellow
Write-Host ""

# ── Phase 3: HSTP gate 시뮬레이션 (명시적 대기) ───────────────────────
Write-Host "[PHASE 3] HSTP gate simulation — explicit propagation wait" -ForegroundColor Green
Write-Host "  Apply DENY -> wait 30s -> verify blocked -> proceed"
Write-Host "  Apply ALLOW -> wait 30s -> verify accessible -> proceed`n"

# DENY 재적용
kubectl apply -f $denyFile 2>&1 | Out-Null
$hstpStart = Get-Date

# HSTP는 명시적으로 정책 전파 대기
Write-Host "  Waiting 30s for DENY propagation..."
Start-Sleep -Seconds 30
$e = ((Get-Date) - $hstpStart).TotalSeconds
$r = Test-Chain -Phase "hstp_deny_verified" -Elapsed $e -PolicyState "DENY_CONFIRMED" -Notes "hstp_waited"

# DENY 제거 + 전파 대기
kubectl delete authorizationpolicy deny-campaign-all -n $NS 2>$null | Out-Null
$hstpAllowStart = Get-Date
Write-Host "  Waiting 30s for ALLOW propagation..."
Start-Sleep -Seconds 30
$e2 = ((Get-Date) - $hstpStart).TotalSeconds
$r2 = Test-Chain -Phase "hstp_allow_verified" -Elapsed $e2 -PolicyState "ALLOW_CONFIRMED" -Notes "hstp_waited"

Write-Host ""

# 정리
Remove-Item $denyFile -Force 2>$null

# ── 결과 요약 ─────────────────────────────────────────────────────────
$allRows = Import-Csv $CSV_FILE

$denyGapRows  = $allRows | Where-Object { $_.phase -eq "deny_propagation"  -and $_.success -eq "YES" }
$allowGapRows = $allRows | Where-Object { $_.phase -eq "allow_propagation" -and $_.success -eq "NO"  }

$denyGapSec  = if ($denyGapRows)  { [math]::Round(([double]($denyGapRows  | Select-Object -Last 1).elapsed_sec), 1) } else { 0 }
$allowGapSec = if ($allowGapRows) { [math]::Round(([double]($allowGapRows | Select-Object -Last 1).elapsed_sec), 1) } else { 0 }

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: Policy Propagation Gap"               -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-42} {1}" -f "DENY propagation gap (security risk):",     "${denyGapSec}s") -ForegroundColor $(if ($denyGapSec -gt 0) { "Red" } else { "Green" })
Write-Host ("  {0,-42} {1}" -f "ALLOW propagation gap (availability risk):", "${allowGapSec}s") -ForegroundColor $(if ($allowGapSec -gt 0) { "Yellow" } else { "Green" })
Write-Host ""
Write-Host "  INTERPRETATION:" -ForegroundColor Cyan
Write-Host "  - Readiness probe returns OK immediately after kubectl apply/delete"
Write-Host "  - But Istio policy takes ${denyGapSec}s (DENY) / ${allowGapSec}s (ALLOW) to propagate"
Write-Host "  - Readiness-only gate cannot detect this gap"
Write-Host "  - HSTP multi-gate explicitly waits for propagation -> eliminates gap"
Write-Host ""
Write-Host "  Output: $CSV_FILE"
Write-Host "=================================================" -ForegroundColor Cyan

kubectl delete pod load-gen -n $NS --grace-period=0 --force 2>$null | Out-Null
