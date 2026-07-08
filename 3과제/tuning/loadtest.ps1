<#
  채점기 스타일 부하 테스트 (loadtest.sh 의 PowerShell 판). config.ps1 을 dot-source 한다.
  API 목록/SLO/부하 모양은 config.ps1 에서 읽으므로 대회 앱이 바뀌어도 config 만 고치면 된다.

  사용법:
    .\loadtest.ps1 <endpoint> [duration 예: 180s] [label]

  각 API 를 채점처럼 측정: 가용성(5초 내 2xx) + 성능(응답시간 <= API별 SLO), 노드 수 타임라인.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Endpoint,
  [string]$Duration = '180s',
  [string]$Label = 'run'
)
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

# ~/bin 을 PATH 앞에 (hey/kubectl)
$bin = Join-Path $env:USERPROFILE 'bin'
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }

$EP = $Endpoint.TrimEnd('/')
$OUT = Join-Path $env:TEMP "tune-$Label"
New-Item -ItemType Directory -Force -Path $OUT | Out-Null

$Hey = (Get-Command hey -ErrorAction SilentlyContinue).Source
$Kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $Hey) { Write-Error 'hey 없음 — 먼저 .\setup.ps1 <cluster> <region> 실행'; exit 1 }
if (-not $Kubectl) { Write-Warning 'kubectl 없음 — 노드 샘플링 생략(가용성/성능은 정상 측정)' }

# --- node/pod 샘플러 (5초 간격, 백그라운드 잡) ---
$sampler = $null
if ($Kubectl) {
  $sampler = Start-Job -ScriptBlock {
    param($NS, $csv, $kubectl)
    while ($true) {
      try { $n = (& $kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch { $n = 0 }
      try { $p = (& $kubectl -n $NS get pods --no-headers 2>$null | Select-String 'Running').Count } catch { $p = 0 }
      $ts = [int][double]::Parse((Get-Date -UFormat %s))
      "$ts,$n,$p" | Add-Content -Path $csv
      Start-Sleep -Seconds 5
    }
  } -ArgumentList $NS, (Join-Path $OUT 'nodes.csv'), $Kubectl
}

# --- 시드 레코드 (idempotent) ---
foreach ($s in $SEEDS) {
  try {
    if ($s.method -eq 'GET') {
      Invoke-WebRequest -Uri "$EP$($s.path)" -UseBasicParsing -TimeoutSec 10 | Out-Null
    } else {
      Invoke-WebRequest -Uri "$EP$($s.path)" -Method $s.method -ContentType 'application/json' -Body $s.body -UseBasicParsing -TimeoutSec 10 | Out-Null
    }
  } catch {}
}

# --- 부하: 모든 API 병렬 (hey) ---
$jobs = @()
foreach ($a in $APIS) {
  $jobs += Start-Job -ScriptBlock {
    param($hey, $dur, $a, $EP, $OUT)
    $out = Join-Path $OUT "$($a.name).csv"
    $err = Join-Path $OUT "$($a.name).err"
    if ($a.method -eq 'GET') {
      & $hey -z $dur -c $a.conc -q $a.qps -o csv "$EP$($a.path)" > $out 2> $err
    } else {
      & $hey -z $dur -c $a.conc -q $a.qps -m $a.method -T application/json -d $a.body -o csv "$EP$($a.path)" > $out 2> $err
    }
  } -ArgumentList $Hey, $Duration, $a, $EP, $OUT
}
Wait-Job $jobs | Out-Null
Remove-Job $jobs

if ($sampler) { Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue }

# --- 채점 (SLO 는 config.ps1 의 $SLOS) ---
python (Join-Path $Here 'score.py') report $OUT $Label $SLOS

# --- 권장값 + 복붙 명령 (측정 → 앱별 늘려/줄여/유지 판정) ---
python (Join-Path $Here 'advise.py') $OUT --slos $SLOS --ns $NS
