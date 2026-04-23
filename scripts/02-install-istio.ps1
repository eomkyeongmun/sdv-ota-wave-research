# =============================================================================
# 02-install-istio.ps1
# Download istioctl and install Istio (default profile) into the kind cluster.
# Usage: .\scripts\02-install-istio.ps1
# =============================================================================
$ErrorActionPreference = "Stop" # 에러 발생 시 즉시 중단하여 꼬임 방지

$ISTIO_VERSION = "1.21.2"
# 프로젝트 루트에 istioctl.exe 고정 저장
# scripts\ 안에서 실행한다고 가정 → 한 단계 위가 프로젝트 루트
$PROJECT_ROOT = (Get-Item (Join-Path $PWD "..")).FullName
$ISTIOCTL     = Join-Path $PROJECT_ROOT "istioctl.exe"

Write-Host "=== [02] Installing Istio $ISTIO_VERSION ===" -ForegroundColor Cyan

# ---- Download istioctl if not already present -------------------------------
if (-not (Test-Path $ISTIOCTL)) {
    Write-Host "Downloading istioctl $ISTIO_VERSION..."

    $url         = "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istioctl-$ISTIO_VERSION-win.zip"
    $zip         = Join-Path $env:TEMP "istioctl_$ISTIO_VERSION.zip"
    $extractPath = Join-Path $env:TEMP "istio_extract_$ISTIO_VERSION"

    if (Test-Path $zip)         { Remove-Item $zip -Force }
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }

    # curl.exe (Windows 11 내장) 로 다운로드 — Invoke-WebRequest 보다 안정적
    Write-Host "Downloading via curl.exe (GitHub releases)..."
    $curlArgs = @("-L", "--retry", "3", "--retry-delay", "5",
                  "--connect-timeout", "30", "--max-time", "300",
                  "-o", $zip, $url)
    $exitCode = (Start-Process -FilePath "curl.exe" -ArgumentList $curlArgs `
                               -Wait -PassThru -NoNewWindow).ExitCode

    if ($exitCode -ne 0 -or -not (Test-Path $zip) -or (Get-Item $zip).Length -lt 1MB) {
        Write-Host "curl.exe 실패 (exit $exitCode). Invoke-WebRequest 로 재시도..." -ForegroundColor Yellow
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing `
                              -TimeoutSec 300 -ErrorAction Stop
        } catch {
            Write-Host "다운로드 실패: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "수동 다운로드 후 프로젝트 루트에 istioctl.exe 를 놓고 재실행하세요." -ForegroundColor Yellow
            Write-Host "URL: $url" -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Host "Extracting..."
    Expand-Archive -Path $zip -DestinationPath $extractPath -Force

    $found = Get-ChildItem -Path $extractPath -Filter "istioctl.exe" -Recurse |
             Select-Object -First 1
    if (-not $found) {
        Write-Host "압축 파일 내 istioctl.exe 를 찾을 수 없습니다." -ForegroundColor Red
        exit 1
    }
    Copy-Item -Path $found.FullName -Destination $ISTIOCTL -Force

    Remove-Item $zip         -Force
    Remove-Item $extractPath -Recurse -Force

    Write-Host "istioctl.exe 저장 완료 -> $ISTIOCTL" -ForegroundColor Green
} else {
    Write-Host "istioctl.exe 이미 존재 — 다운로드 생략." -ForegroundColor Yellow
}

# 실행 가능 여부 확인
Write-Host "istioctl version: $(& $ISTIOCTL version --remote=false)"

# ---- Pre-flight check -------------------------------------------------------
Write-Host ""
Write-Host "=== Pre-flight check ===" -ForegroundColor Cyan
& $ISTIOCTL x precheck

# ---- Install Istio (default profile) ----------------------------------------
Write-Host ""
Write-Host "=== Installing Istio with 'default' profile ===" -ForegroundColor Cyan
& $ISTIOCTL install --set profile=default -y

# ---- Wait for istiod ---------------------------------------------------------
Write-Host ""
Write-Host "=== Waiting for istiod to be ready ===" -ForegroundColor Cyan
# istio-system 네임스페이스가 생성될 때까지 잠시 대기
Start-Sleep -Seconds 5
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

Write-Host ""
Write-Host "=== Istio components ===" -ForegroundColor Cyan
kubectl get pods -n istio-system

Write-Host ""
Write-Host "=== [02] DONE ===" -ForegroundColor Green
Write-Host "Next step: .\scripts\03-deploy-services.ps1"