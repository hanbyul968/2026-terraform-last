<#
  튜닝 되돌리기 — Terraform 경유 (kubectl 직접 수정 금지)

  이전 버전은 `kubectl set resources` / `kubectl patch hpa` 로 하드코딩된 옛 값을
  라이브에 되돌렸다. 그 값은 어느 회차 기준인지 알 수 없는 상수였고, Terraform
  state 와도 어긋나 드리프트를 더 키웠다.

  이제 되돌리기는 두 가지 방식만 제공한다. 둘 다 Terraform 이 반영한다.
    (기본)  tuning.auto.tfvars.json 을 삭제 → terraform.tfvars 의 apps 값으로 복귀
    -App x  특정 앱의 튜닝만 제거 → 그 앱만 apps 값으로 복귀

  사용법:
    .\rollback.ps1                # 전체 튜닝 제거 (권장: 가장 확실한 알려진 상태)
    .\rollback.ps1 -App user      # user 튜닝만 제거
    .\rollback.ps1 -NoApply       # 파일만 정리하고 apply 는 사용자가 직접
#>
[CmdletBinding()]
param(
  [string]$App,
  [switch]$RunTerraform
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

$TuningFile = Join-Path $TF_DIR 'tuning.auto.tfvars.json'

function Invoke-Apply {
  # 기본은 apply 하지 않는다(tfvars 기록만). 반영까지 원하면 -RunTerraform 을 준다.
  if (-not $RunTerraform) {
    Write-Host "기록만 완료 — 반영은 직접: cd $TF_DIR ; terraform apply" -ForegroundColor Yellow
    return
  }
  # 인수는 배열로 넘긴다. "-target=a.b" 를 한 문자열로 주면 PowerShell 이 토큰을 쪼개
  # terraform 이 'Invalid target' / 'Too many command line arguments' 로 죽는다(실측).
  $tfArgs = @('apply', '-auto-approve', '-input=false',
    '-target', 'kubernetes_deployment.app',
    '-target', 'kubernetes_horizontal_pod_autoscaler_v2.app')
  Push-Location $TF_DIR
  try {
    & terraform @tfArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform apply 실패 (exit=$LASTEXITCODE)" }
  } finally { Pop-Location }
}

if (-not (Test-Path $TuningFile)) {
  Write-Host '튜닝값이 없습니다 — 이미 terraform.tfvars 의 apps 값으로 동작 중입니다.'
  exit 0
}

if (-not $App) {
  # 전체 제거. 백업을 남겨 필요하면 되살릴 수 있게 한다.
  $backup = "$TuningFile.bak"
  Copy-Item $TuningFile $backup -Force
  Remove-Item $TuningFile -Force
  Write-Host "전체 튜닝 제거 (백업: $backup)" -ForegroundColor Yellow
  Write-Host 'apps 값(terraform.tfvars)으로 복귀합니다.' -ForegroundColor Yellow
  Invoke-Apply
  exit 0
}

# 특정 앱만 제거
$obj = Get-Content $TuningFile -Raw -Encoding UTF8 | ConvertFrom-Json
$map = @{}
if ($obj.app_tuning) {
  foreach ($p in $obj.app_tuning.PSObject.Properties) {
    if ($p.Name -eq $App) { continue }
    $e = @{}
    foreach ($f in $p.Value.PSObject.Properties) { $e[$f.Name] = [int]$f.Value }
    $map[$p.Name] = $e
  }
}

if ($map.Count -eq 0) {
  Remove-Item $TuningFile -Force
  Write-Host "$App 제거 후 남은 튜닝이 없어 파일을 삭제했습니다." -ForegroundColor Yellow
} else {
  # ⚠ BOM 금지: Terraform JSON 파서가 BOM 을 거부한다("Invalid start of value").
  $json = (@{ app_tuning = $map } | ConvertTo-Json -Depth 10)
  [IO.File]::WriteAllText($TuningFile, $json, (New-Object Text.UTF8Encoding($false)))
  Write-Host "$App 튜닝 제거 — 남은 앱: $($map.Keys -join ', ')" -ForegroundColor Cyan
}
Invoke-Apply
