<#
.SYNOPSIS
  3과제 모니터링 대시보드 실행 (Windows PowerShell)
.DESCRIPTION
  Flask 대시보드를 로컬에서 시작합니다.
  브라우저에서 http://localhost:8080 으로 접속하세요.
  
  사용:  .\dashboard.ps1
         .\dashboard.ps1 -Port 9090 -Namespace app -WafLogGroup aws-waf-logs-wsi2026
#>
param(
    [int]$Port = 8080,
    [string]$Namespace = "app",
    [string]$WafLogGroup = "aws-waf-logs-wsi2026",
    [string]$WafRegion = "us-east-1",
    [switch]$Demo
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1) Python + Flask 확인
try {
    $pyVer = python --version 2>&1
    Write-Host "[OK] $pyVer" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] python을 찾을 수 없습니다. Python 3을 설치하세요:" -ForegroundColor Red
    Write-Host "  winget install --id Python.Python.3.12 -e" -ForegroundColor Yellow
    exit 1
}

# flask 설치 확인
$flaskCheck = python -c "import flask" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] flask가 없습니다. 설치 중..." -ForegroundColor Yellow
    pip install flask
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] flask 설치 실패. 수동으로: pip install flask" -ForegroundColor Red
        exit 1
    }
}

# 2) 대시보드 시작
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  3과제 모니터링 대시보드" -ForegroundColor Cyan
Write-Host "  http://localhost:$Port" -ForegroundColor White
Write-Host "  (브라우저에서 위 주소로 접속하세요)" -ForegroundColor Gray
Write-Host "  종료: Ctrl+C" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$args_list = @(
    "$here\dashboard.py",
    "--port", $Port,
    "--namespace", $Namespace,
    "--waf-log-group", $WafLogGroup,
    "--waf-region", $WafRegion
)

if ($Demo) {
    $args_list += "--demo"
}

# 브라우저 자동 열기 (1초 후)
Start-Job -ScriptBlock {
    Start-Sleep -Seconds 2
    Start-Process "http://localhost:$using:Port"
} | Out-Null

# Flask 실행 (foreground — Ctrl+C로 종료)
python @args_list
