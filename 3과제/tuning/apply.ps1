<#
  튜닝값 반영 — Terraform 경유 (kubectl 직접 수정 금지)

  이전 버전은 `kubectl patch hpa` / `kubectl set resources` 를 하드코딩해 실행했다.
  그 결과 라이브 상태가 Terraform state 와 어긋나(드리프트), 채점 회차에 실제로
  적용된 구성이 무엇인지 사후에 알 수 없었고, 누군가 terraform apply 를 하면
  튜닝이 조용히 원복되는 상태였다.

  이제 이 스크립트는 tuning.auto.tfvars.json 에 값을 쓰고 terraform 이 반영한다.
  Terraform 이 항상 단일 진실 공급원이다.

  사용법:
    .\apply.ps1 -App user -Request 120 -Target 60 -Min 2 -Max 8
    .\apply.ps1 -App product -Target 60          # 일부 값만 변경
    .\apply.ps1 -Show                            # 현재 튜닝값 확인
    .\apply.ps1 -Clear                           # 튜닝 전부 제거(apps 값으로 복귀)
#>
[CmdletBinding()]
param(
  [string]$App,
  [int]$Request = 0,
  [int]$Target = 0,
  [int]$Min = 0,
  [int]$Max = 0,
  [switch]$Show,
  [switch]$Clear,
  [switch]$NoApply
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

$TuningFile = Join-Path $TF_DIR 'tuning.auto.tfvars.json'

function Read-TuningMap {
  if (-not (Test-Path $TuningFile)) { return @{} }
  $obj = Get-Content $TuningFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $out = @{}
  if ($obj.app_tuning) {
    foreach ($p in $obj.app_tuning.PSObject.Properties) {
      $e = @{}
      foreach ($f in $p.Value.PSObject.Properties) { $e[$f.Name] = [int]$f.Value }
      $out[$p.Name] = $e
    }
  }
  return $out
}

function Invoke-Apply {
  if ($NoApply) { Write-Host 'NoApply 지정 — terraform apply 생략' -ForegroundColor Yellow; return }
  Push-Location $TF_DIR
  try {
    & terraform apply -auto-approve -input=false -target=kubernetes_deployment.app -target=kubernetes_horizontal_pod_autoscaler_v2.app
    if ($LASTEXITCODE -ne 0) { throw "terraform apply 실패 (exit=$LASTEXITCODE)" }
  } finally { Pop-Location }
}

if ($Show) {
  if (-not (Test-Path $TuningFile)) { Write-Host '튜닝값 없음 (terraform.tfvars 의 apps 값 사용 중)'; exit 0 }
  Get-Content $TuningFile -Raw -Encoding UTF8 | Write-Host
  exit 0
}

if ($Clear) {
  if (Test-Path $TuningFile) {
    Remove-Item $TuningFile -Force
    Write-Host "삭제: $TuningFile — apps 값으로 복귀합니다." -ForegroundColor Yellow
    Invoke-Apply
  } else { Write-Host '튜닝값이 이미 없습니다.' }
  exit 0
}

if (-not $App) { throw '-App 을 지정하세요 (또는 -Show / -Clear).' }

$map = Read-TuningMap
$entry = if ($map[$App]) { $map[$App] } else { @{} }

# 0 은 '변경 없음'을 뜻한다 → 기존 값 유지. request 에 0m 을 쓰면 파드가 CPU 를
# 전혀 요청하지 않아 스케줄링/HPA 계산이 망가지므로 특히 중요하다.
if ($Request -gt 0) { $entry.cpu_request_m = $Request }
if ($Target -gt 0) { $entry.hpa_target_cpu = $Target }
if ($Min -gt 0) { $entry.min_replicas = $Min }
if ($Max -gt 0) { $entry.max_replicas = $Max }

if ($entry.Count -eq 0) { throw '변경할 값이 없습니다 (-Request/-Target/-Min/-Max 중 하나 이상 지정).' }

$map[$App] = $entry
(@{ app_tuning = $map } | ConvertTo-Json -Depth 10) | Set-Content $TuningFile -Encoding UTF8

Write-Host "기록: $App -> $($entry | ConvertTo-Json -Compress)" -ForegroundColor Cyan
Write-Host "파일: $TuningFile" -ForegroundColor DarkGray
Invoke-Apply
