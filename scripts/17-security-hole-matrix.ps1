<#
.SYNOPSIS
    Week 2/3 보완 - 9가지 e2e 조합별 보안 홀 지속 시간 측정
    각 비활성화 순서(D1/D2/D3)에서 attacker가 체인 외부에서
    하위 서비스에 직접 접근할 수 있는 시간을 측정한다.

    보안 홀 정의:
      upstream 서비스가 제거된 시점부터 해당 upstream이 보호하던
      downstream 서비스도 제거(또는 policy 차단)될 때까지의 시간
#>

$ErrorActionPreference = "Continue"
$NS           = "ota-pipeline"
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$LOGS_DIR     = Join-Path $PROJECT_ROOT "logs"
$TIMESTAMP    = Get-Date -Format "yyyyMMdd-HHmmss"
$CSV_FILE     = Join-Path $LOGS_DIR "security-hole-matrix-$TIMESTAMP.csv"

if (-not (Test-Path $LOGS_DIR)) { New-Item -ItemType Directory -Path $LOGS_DIR | Out-Null }

# 비활성화 순서 정의
# D1: deploy->package->campaign->auth  (safe, downstream-first)
# D2: auth->campaign->package->deploy  (unsafe, upstream-first)
# D3: campaign->package->auth->deploy  (partial unsafe)
$deactOrders = [ordered]@{
    "D1" = @("deploy","package","campaign","auth")
    "D2" = @("auth","campaign","package","deploy")
    "D3" = @("campaign","package","auth","deploy")
}

# 보안 홀 분석:
# 어떤 서비스가 제거될 때 "그 서비스가 게이트키핑하던 downstream"이 노출되는가?
# 체인: auth -> campaign -> package -> deploy
# auth 제거 시: campaign/package/deploy 노출
# campaign 제거 시 (auth 없는 상태): package/deploy 노출
# package 제거 시 (auth/campaign 없는 상태): deploy 노출
$downstream = @{
    "auth"     = @("campaign","package","deploy")
    "campaign" = @("package","deploy")
    "package"  = @("deploy")
    "deploy"   = @()
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Security Hole Matrix — D1/D2/D3 Comparison"    -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

Set-Content -Path $CSV_FILE -Value "deact_order,step,removed_svc,exposed_svcs,hole_start_sec,hole_end_sec,hole_duration_sec,attacker_success,attacker_total" -Encoding UTF8

function Ensure-AllRunning {
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
    }
    foreach ($svc in @("auth","campaign","package","deploy")) {
        kubectl rollout status deployment/$svc -n $NS --timeout=90s 2>&1 | Out-Null
    }
    # 정책 없는 상태 확인 (no-policy baseline)
    kubectl delete authorizationpolicy --all -n $NS 2>$null | Out-Null
    kubectl delete networkpolicy --all -n $NS 2>$null | Out-Null
    kubectl apply -f (Join-Path $PROJECT_ROOT "k8s\peer-auth-permissive.yaml") 2>&1 | Out-Null
    Start-Sleep -Seconds 5
}

function Test-AttackerAccess {
    param([string]$Target)
    $raw = kubectl exec attacker -n $NS -- `
        curl -s -o /dev/null -w "%{http_code}" `
        --connect-timeout 2 --max-time 3 `
        "http://${Target}:8080/health" 2>$null
    return ($raw | Select-Object -Last 1).Trim()
}

# attacker pod 준비
kubectl delete pod attacker -n $NS --grace-period=0 --force 2>$null | Out-Null
Start-Sleep -Seconds 2
kubectl run attacker -n $NS --image=curlimages/curl:8.6.0 --restart=Never --command -- sleep 3600 2>&1 | Out-Null
$waited = 0
do { Start-Sleep -Seconds 3; $waited += 3
     $s = kubectl get pod attacker -n $NS --no-headers 2>$null
} while ($s -notmatch "Running" -and $waited -lt 60)
Write-Host "Attacker pod ready.`n"

foreach ($order in $deactOrders.Keys) {
    $sequence = $deactOrders[$order]
    Write-Host "--- $order : $($sequence -join ' -> ') ---" -ForegroundColor Yellow

    Ensure-AllRunning

    $startTime  = Get-Date
    $holeOpen   = $false
    $holeStart  = 0.0
    $holeTotal  = 0.0
    $removedSvcs = @()

    foreach ($svc in $sequence) {
        # 서비스 제거
        kubectl scale deployment $svc -n $NS --replicas=0 2>&1 | Out-Null
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
        $removedSvcs += $svc

        # 이 서비스 제거로 노출되는 downstream 계산
        # (아직 살아있는 downstream 중 auth 게이트웨이 없이 접근 가능한 것들)
        $exposed = @()
        if ($svc -eq "auth" -or ($removedSvcs -contains "auth")) {
            # auth가 이미 제거된 상태 — 남은 서비스들 직접 노출
            foreach ($ds in @("campaign","package","deploy")) {
                if (-not ($removedSvcs -contains $ds)) { $exposed += $ds }
            }
        }

        if ($exposed.Count -gt 0 -and -not $holeOpen) {
            $holeOpen  = $true
            $holeStart = $elapsed
            Write-Host ("  [HOLE OPEN  t={0,5}s] removed={1} exposed={2}" -f $elapsed, $svc, ($exposed -join ",")) -ForegroundColor Red
        } elseif ($exposed.Count -eq 0 -and $holeOpen) {
            $holeDur   = [math]::Round($elapsed - $holeStart, 2)
            $holeTotal += $holeDur
            $holeOpen  = $false
            Write-Host ("  [HOLE CLOSE t={0,5}s] duration={1}s" -f $elapsed, $holeDur) -ForegroundColor Green
        } else {
            Write-Host ("  [step       t={0,5}s] removed={1}" -f $elapsed, $svc) -ForegroundColor Gray
        }

        # attacker 접근 시도 (15s 동안 측정)
        $probeOk = 0; $probeTotal = 0
        $probeEnd = (Get-Date).AddSeconds(15)
        $targets = @("campaign","package","deploy") | Where-Object { -not ($removedSvcs -contains $_) }

        while ((Get-Date) -lt $probeEnd -and $targets.Count -gt 0) {
            foreach ($t in $targets) {
                $code = Test-AttackerAccess -Target $t
                $probeTotal++
                if ($code -match "^2") { $probeOk++ }
            }
            Start-Sleep -Seconds 3
        }

        $expStr = if ($exposed.Count -gt 0) { $exposed -join "+" } else { "none" }
        Add-Content -Path $CSV_FILE -Value "$order,$svc,$svc,$expStr,$elapsed,,$,$probeOk,$probeTotal" -Encoding UTF8
        Write-Host ("    attacker success: {0}/{1}" -f $probeOk, $probeTotal)
    }

    # 홀이 끝까지 열려있으면 (모든 서비스 제거로 자연 소멸)
    if ($holeOpen) {
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
        $holeDur = [math]::Round($elapsed - $holeStart, 2)
        $holeTotal += $holeDur
        Write-Host ("  [HOLE CLOSE t={0,5}s] duration={1}s (all removed)" -f $elapsed, $holeDur) -ForegroundColor Green
    }

    Write-Host ("  Total hole duration: {0}s`n" -f $holeTotal) -ForegroundColor $(if ($holeTotal -eq 0) { "Green" } else { "Red" })
}

# 최종 요약
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  SECURITY HOLE MATRIX RESULTS"                   -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

$rows = Import-Csv $CSV_FILE
foreach ($o in @("D1","D2","D3")) {
    $oRows = $rows | Where-Object { $_.deact_order -eq $o }
    $ok    = ($oRows | Measure-Object { [int]$_.attacker_success } -Sum).Sum
    $tot   = ($oRows | Measure-Object { [int]$_.attacker_total   } -Sum).Sum
    $pct   = if ($tot -gt 0) { [math]::Round($ok/$tot*100,1) } else { 0 }
    $col   = if ($pct -eq 0) { "Green" } else { "Red" }
    Write-Host ("  {0}: attacker success {1}/{2} ({3}%)" -f $o, $ok, $tot, $pct) -ForegroundColor $col
}

Write-Host ""
Write-Host "  Output: $CSV_FILE"
Write-Host "=================================================" -ForegroundColor Cyan

# 정리
kubectl delete pod attacker -n $NS --grace-period=0 --force 2>$null | Out-Null
foreach ($svc in @("auth","campaign","package","deploy")) {
    kubectl scale deployment $svc -n $NS --replicas=1 2>&1 | Out-Null
}
