<#
  config 기반 hill-climbing 정밀 튜너 (autotune-hc.sh 의 PowerShell 판).
  한 점에서 시작해 두 knob(cpu request, HPA util)을 모든 앱에 균일 적용하며 개선한다.
  autotune.ps1 보다 깨끗한 측정: 각 시도 전에 노드를 baseline 으로 drain(Karpenter 통합 대기)하고 더 길게 부하.

  knob: cpu(step 100m, [100..1000]), util(step 5, [40..75]).
  사용법:
    .\autotune-hc.ps1 <endpoint> [duration] [start_cpu] [start_util] [max_moves]
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Endpoint,
  [string]$Duration = '120s',
  [int]$Cpu = 300,
  [int]$Util = 55,
  [int]$MaxMoves = 4
)
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

$bin = Join-Path $env:USERPROFILE 'bin'
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
$EP = $Endpoint.TrimEnd('/')

if (-not (Get-Command hey -ErrorAction SilentlyContinue) -or -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Error 'hey/kubectl 없음 — .\setup.ps1 먼저'; exit 1
}
$Log = Join-Path $env:TEMP 'autotune-hc-results.csv'
'trial,cpu,util,avg_perf,min_avail,nodes_avg,score' | Set-Content -Path $Log

$APPS = $APIS | ForEach-Object { $_.name }
$script:Trial = 0

function Clamp-Cpu  { param($v) [Math]::Max(100, [Math]::Min(1000, $v)) }
function Clamp-Util { param($v) [Math]::Max(40,  [Math]::Min(75,   $v)) }

function Set-State {
  param($cpu, $util)
  foreach ($app in $APPS) {
    kubectl -n $NS set resources "deploy/$app" --requests=cpu="${cpu}m" 2>$null | Out-Null
    $patch = @{ spec = @{ minReplicas = 2; maxReplicas = 10; metrics = @(@{ type = 'Resource'; resource = @{ name = 'cpu'; target = @{ type = 'Utilization'; averageUtilization = $util } } }) } } | ConvertTo-Json -Depth 10 -Compress
    kubectl -n $NS patch hpa $app --type=merge -p $patch 2>$null | Out-Null
  }
  foreach ($app in $APPS) { kubectl -n $NS rollout status "deploy/$app" --timeout=180s 2>$null | Out-Null }
}

function Invoke-Drain {
  Write-Host '    draining nodes to baseline...'
  for ($i = 0; $i -lt 36; $i++) {
    try { $n = (kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch { $n = 9 }
    if ($n -le 3) { Write-Host "    drained to $n"; return }
    Start-Sleep -Seconds 5
  }
  Write-Host '    drain timeout'
}

function Measure-State {
  param($cpu, $util)
  $script:Trial++
  $label = "hc$($script:Trial)_${cpu}_${util}"
  Set-State $cpu $util
  Invoke-Drain
  & (Join-Path $Here 'loadtest.ps1') $EP $Duration $label *> $null
  $out = Join-Path $env:TEMP "tune-$label"
  $r = (python (Join-Path $Here 'score.py') score $out $SLOS $AVAIL_GATE $COST_PENALTY) -split '\s+'
  $ap, $ma, $na, $sc = $r[0], $r[1], $r[2], $r[3]
  "$($script:Trial),$cpu,$util,$ap,$ma,$na,$sc" | Add-Content -Path $Log
  Write-Host ("    trial{0,-2} cpu={1} util={2} -> perf={3} avail={4} nodes={5} SCORE={6}" -f $script:Trial, $cpu, $util, $ap, $ma, $na, $sc)
  [double]$sc
}

Write-Host "### hill-climb from cpu=$Cpu util=$Util  (dur=$Duration, max moves=$MaxMoves, apps=[$($APPS -join ' ')])"
$Best = Measure-State $Cpu $Util
$moves = 0
while ($moves -lt $MaxMoves) {
  $improved = $false
  $cands = @(
    @{ c = (Clamp-Cpu ($Cpu + 100)); u = $Util }
    @{ c = (Clamp-Cpu ($Cpu - 100)); u = $Util }
    @{ c = $Cpu; u = (Clamp-Util ($Util + 5)) }
    @{ c = $Cpu; u = (Clamp-Util ($Util - 5)) }
  )
  foreach ($cand in $cands) {
    if ($cand.c -eq $Cpu -and $cand.u -eq $Util) { continue }
    Write-Host ">>> try cpu=$($cand.c) util=$($cand.u) (best $Best)"
    $sc = Measure-State $cand.c $cand.u
    if ($sc -gt $Best) {
      Write-Host '    ^ improves -> MOVE'
      $Best = $sc; $Cpu = $cand.c; $Util = $cand.u; $improved = $true; $moves++
      break
    }
  }
  if (-not $improved) { Write-Host '### local optimum'; break }
}

Write-Host ''
Write-Host "### BEST: cpu=${Cpu}m util=$Util  score=$Best"
Set-State $Cpu $Util
Write-Host "### terraform: requests.cpu=`"${Cpu}m`", HPA averageUtilization=$Util (all apps)"
Write-Host "All trials: $Log"
Import-Csv $Log | Format-Table -AutoSize | Out-String | Write-Host
