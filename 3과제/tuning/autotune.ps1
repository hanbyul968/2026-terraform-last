<#
  config 기반 자동 튜너 (autotune.sh 의 PowerShell 판).
  라이브 클러스터를 patch 하며 조합을 스윕하고(빠름, terraform 재적용 없음),
  각 조합마다 채점 스타일 부하 테스트를 돌려 rubric(성능효율+고가용성+비용)으로 점수화,
  최고 조합을 선언하고 그대로 적용해 둔다.

  각 조합은 config.ps1 의 모든 앱에 동일한 (cpu request, HPA util, min, max) 를 적용한다.

  사용법:
    .\autotune.ps1 <endpoint> [duration]
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Endpoint,
  [string]$Duration = '90s'
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
$Results = Join-Path $env:TEMP 'autotune-results.csv'
'combo,avg_perf,min_avail,nodes_avg,score' | Set-Content -Path $Results

$APPS = $APIS | ForEach-Object { $_.name }

# --- 후보 그리드: name | cpu | util | min | max (모든 앱에 적용) ---
$COMBOS = @(
  @{ name = 'baseline';       cpu = '300m'; util = 55; min = 2; max = 10 }
  @{ name = 'lean-cpu';       cpu = '200m'; util = 55; min = 2; max = 10 }
  @{ name = 'rich-cpu';       cpu = '500m'; util = 55; min = 2; max = 10 }
  @{ name = 'aggressive-hpa'; cpu = '300m'; util = 45; min = 3; max = 12 }
  @{ name = 'calm-hpa';       cpu = '300m'; util = 65; min = 2; max = 8 }
  @{ name = 'cost-min';       cpu = '200m'; util = 65; min = 2; max = 6 }
)

function Invoke-PatchAll {
  param($cpu, $util, $min, $max)
  foreach ($app in $APPS) {
    kubectl -n $NS set resources "deploy/$app" --requests=cpu=$cpu 2>$null | Out-Null
    $patch = @{ spec = @{ minReplicas = $min; maxReplicas = $max; metrics = @(@{ type = 'Resource'; resource = @{ name = 'cpu'; target = @{ type = 'Utilization'; averageUtilization = $util } } }) } } | ConvertTo-Json -Depth 10 -Compress
    kubectl -n $NS patch hpa $app --type=merge -p $patch 2>$null | Out-Null
  }
  foreach ($app in $APPS) { kubectl -n $NS rollout status "deploy/$app" --timeout=180s 2>$null | Out-Null }
}

function Get-TrialScore {
  param($Label)
  $out = Join-Path $env:TEMP "tune-$Label"
  # score.py score -> "avg mav navg score"
  (python (Join-Path $Here 'score.py') score $out $SLOS $AVAIL_GATE $COST_PENALTY) -split '\s+'
}

Write-Host "### autotune: $($COMBOS.Count) combos x $Duration  apps=[$($APPS -join ' ')]  endpoint=$EP"
foreach ($c in $COMBOS) {
  Write-Host ''
  Write-Host ">>> combo=$($c.name)  cpu=$($c.cpu) util=$($c.util) replicas=$($c.min)-$($c.max)"
  Invoke-PatchAll $c.cpu $c.util $c.min $c.max
  Start-Sleep -Seconds 45   # HPA/Karpenter 가 baseline 으로 돌아가도록
  & (Join-Path $Here 'loadtest.ps1') $EP $Duration $c.name *> $null
  $r = Get-TrialScore $c.name
  $ap, $ma, $na, $sc = $r[0], $r[1], $r[2], $r[3]
  Write-Host ("    perf_avg={0} avail_min={1} nodes_avg={2} SCORE={3}" -f $ap, $ma, $na, $sc)
  "$($c.name),$ap,$ma,$na,$sc" | Add-Content -Path $Results
}

Write-Host ''
Write-Host '### ranked (higher = better)'
$rows = Import-Csv $Results | Sort-Object { [double]$_.score } -Descending
$rows | Format-Table -AutoSize | Out-String | Write-Host
$WName = $rows[0].combo

Write-Host "### WINNER: $WName — re-applying to live cluster"
$win = $COMBOS | Where-Object { $_.name -eq $WName } | Select-Object -First 1
if ($win) {
  Invoke-PatchAll $win.cpu $win.util $win.min $win.max
  Write-Host ''
  Write-Host '### terraform/k8s_apps.tf 반영값 (모든 앱):'
  Write-Host ("  requests.cpu = `"{0}`",  HPA averageUtilization = {1},  min={2} max={3}" -f $win.cpu, $win.util, $win.min, $win.max)
}
Write-Host ''
Write-Host "Full results: $Results"
