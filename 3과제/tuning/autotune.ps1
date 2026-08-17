<#
  HPA 전용 실제점수 튜너.

  requests.cpu 는 건드리지 않는다(Deployment 롤아웃 없음).
  선택한 한 앱의 minReplicas / maxReplicas / CPU averageUtilization 만 후보별로 patch하고,
  config.ps1 부하를 실행한 뒤 공식 채점식(가용성+성능+비용, 36점)으로 승자를 고른다.

  사용법:
    .\autotune.ps1 -App user -Duration 90s
    .\autotune.ps1 -App stress -Duration 90s -Refine
    .\autotune.ps1 -App product -DryRun

  -Refine : 1차 승자 주변(min ±1, max ±2, target ±10)을 추가 탐색한다.
  -DrainSeconds N : 후보 사이에 원래 HPA로 복원하고 기준 노드+1 이하가 될 때까지 최대 N초 대기.
                    0이면 빠르지만 이전 후보 노드가 비용 측정에 남을 수 있다.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$App,
  [string]$Duration = '90s',
  [string]$Url = '',
  [int]$SettleSeconds = 20,
  [int]$DrainSeconds = 0,
  [switch]$Refine,
  [switch]$DryRun,
  [switch]$RestoreOriginal
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

$bin = Join-Path $env:USERPROFILE 'bin'
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
if (-not $Url) { $Url = $ENDPOINT }
if (-not $Url -or $Url -like '*REPLACE-ME*') { throw 'config.ps1 ENDPOINT 또는 -Url 을 지정하세요' }
$EP = $Url.TrimEnd('/')
$APPS = @($APIS | ForEach-Object { $_.name })
if ($APPS -notcontains $App) { throw "unknown app '$App' — config.ps1 앱: $($APPS -join ', ')" }
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { throw 'kubectl 없음 — .\setup.ps1 먼저' }
if (-not $DryRun -and -not (Get-Command hey -ErrorAction SilentlyContinue)) { throw 'hey 없음 — .\setup.ps1 먼저' }

function Get-HpaState([string]$name) {
  $h = kubectl -n $NS get hpa $name -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $h) { throw "HPA 조회 실패: $name" }
  $metric = @($h.spec.metrics | Where-Object { $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' }) | Select-Object -First 1
  if (-not $metric) { throw "CPU Utilization metric 없음: $name" }
  [pscustomobject]@{
    min = [int]$h.spec.minReplicas
    max = [int]$h.spec.maxReplicas
    target = [int]$metric.resource.target.averageUtilization
  }
}

function Set-HpaState([string]$name, [int]$min, [int]$max, [int]$target) {
  if ($min -lt 2) { $min = 2 } # PDB minAvailable=1 + 노드 장애 가용성
  if ($max -lt $min) { $max = $min }
  $target = [math]::Max(25, [math]::Min(90, $target))
  $patch = @{
    spec = @{
      minReplicas = $min
      maxReplicas = $max
      metrics = @(@{
        type = 'Resource'
        resource = @{
          name = 'cpu'
          target = @{ type = 'Utilization'; averageUtilization = $target }
        }
      })
    }
  } | ConvertTo-Json -Depth 10 -Compress
  $pf = Join-Path $env:TEMP "hpa-tune-$name.json"
  $patch | Set-Content -Path $pf -Encoding ascii -NoNewline
  kubectl -n $NS patch hpa $name --type=merge --patch-file $pf | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "HPA patch 실패: $name" }
}

function Wait-Drain([int]$seconds, $original) {
  if ($seconds -le 0) { return }
  Set-HpaState $App $original.min $original.max $original.target
  $targetNodes = [int]$COST_BASELINE_NODES + 1
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $seconds) {
    $n = 0
    try { $n = (kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch {}
    if ($n -ge 1 -and $n -le $targetNodes) {
      Write-Host "    drain: nodes=$n (비교 기준 복귀)"
      return
    }
    Start-Sleep -Seconds 10
  }
  Write-Warning "drain ${seconds}s timeout — 이전 후보 노드가 비용 측정에 남을 수 있습니다"
}

$Original = Get-HpaState $App
if ($RestoreOriginal) {
  Set-HpaState $App $Original.min $Original.max $Original.target
  Write-Host "복원 완료: $App min=$($Original.min) max=$($Original.max) target=$($Original.target)%"
  exit 0
}

$Candidates = New-Object System.Collections.Generic.List[object]
$Seen = @{}
function Add-Candidate([string]$name, [int]$min, [int]$max, [int]$target) {
  $min = [math]::Max(2, $min)
  $max = [math]::Max($min, $max)
  $target = [math]::Max(25, [math]::Min(90, $target))
  $key = "$min/$max/$target"
  if (-not $Seen.ContainsKey($key)) {
    $Seen[$key] = $true
    $Candidates.Add([pscustomobject]@{ name=$name; min=$min; max=$max; target=$target })
  }
}

# 현재점 주변의 독립 효과 + 결합 효과. 앱/트래픽이 바뀌어도 라이브 값을 중심으로 생성한다.
Add-Candidate 'baseline'       $Original.min       $Original.max       $Original.target
Add-Candidate 'target-down'    $Original.min       $Original.max       ($Original.target - 15)
Add-Candidate 'target-up'      $Original.min       $Original.max       ($Original.target + 15)
Add-Candidate 'warm-min'       ($Original.min + 1) $Original.max       $Original.target
Add-Candidate 'max-up'         $Original.min       ($Original.max + 2) $Original.target
Add-Candidate 'aggressive'     ($Original.min + 1) ($Original.max + 2) ($Original.target - 15)

Write-Host "### HPA-only tune: app=$App original min=$($Original.min) max=$($Original.max) target=$($Original.target)%"
Write-Host "### requests.cpu 변경 없음 / Deployment 롤아웃 없음"
Write-Host "### 1차 후보 $($Candidates.Count)개 x $Duration"
$Candidates | Format-Table name,min,max,target -AutoSize | Out-String | Write-Host
if ($DryRun) { exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ResultsPath = Join-Path $env:TEMP "hpa-tune-$App-$stamp.csv"
'name,min,max,target,focus_perf,min_avail,nodes_avg,total' | Set-Content $ResultsPath -Encoding ascii
$Rows = New-Object System.Collections.Generic.List[object]

function Invoke-Candidate($c) {
  Write-Host ""
  Write-Host ">>> $($c.name): min=$($c.min) max=$($c.max) target=$($c.target)%" -ForegroundColor Cyan
  Wait-Drain $DrainSeconds $Original
  Set-HpaState $App $c.min $c.max $c.target
  if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
  $label = "hpa-$App-$stamp-$($c.name)"
  & (Join-Path $Here 'loadtest.ps1') -Url $EP -Duration $Duration -Label $label *> $null
  if ($LASTEXITCODE -ne 0) { throw "loadtest 실패: $label" }
  $out = Join-Path $env:TEMP "tune-$label"
  $raw = python (Join-Path $Here 'score.py') score $out $SLOS $AVAIL_GATE $COST_PENALTY $App
  if ($LASTEXITCODE -ne 0) { throw "score 실패: $label" }
  $v = @($raw -split '\s+' | Where-Object { $_ })
  if ($v.Count -lt 4) { throw "score 출력 오류: $raw" }
  $row = [pscustomobject]@{
    name=$c.name; min=$c.min; max=$c.max; target=$c.target
    focus_perf=[double]$v[0]; min_avail=[double]$v[1]
    nodes_avg=[double]$v[2]; total=[double]$v[3]
  }
  $Rows.Add($row)
  "$($row.name),$($row.min),$($row.max),$($row.target),$($row.focus_perf),$($row.min_avail),$($row.nodes_avg),$($row.total)" | Add-Content $ResultsPath
  Write-Host ("    perf={0:N1}% avail_min={1:N1}% nodes={2:N2} official={3:N1}/36" -f $row.focus_perf,$row.min_avail,$row.nodes_avg,$row.total)
}

try {
  $first = @($Candidates)
  foreach ($c in $first) { Invoke-Candidate $c }

  if ($Refine) {
    $best1 = $Rows | Sort-Object -Property `
      @{Expression={[double]$_.total};Descending=$true}, `
      @{Expression={[double]$_.nodes_avg};Ascending=$true}, `
      @{Expression={[double]$_.focus_perf};Descending=$true} | Select-Object -First 1
    Write-Host ""
    Write-Host "### refine around $($best1.name): $($best1.min)/$($best1.max)/$($best1.target)"
    $before = $Candidates.Count
    Add-Candidate 'refine-min-down' ($best1.min - 1) $best1.max $best1.target
    Add-Candidate 'refine-min-up'   ($best1.min + 1) $best1.max $best1.target
    Add-Candidate 'refine-max-down' $best1.min ($best1.max - 2) $best1.target
    Add-Candidate 'refine-max-up'   $best1.min ($best1.max + 2) $best1.target
    Add-Candidate 'refine-target-down' $best1.min $best1.max ($best1.target - 10)
    Add-Candidate 'refine-target-up'   $best1.min $best1.max ($best1.target + 10)
    for ($i=$before; $i -lt $Candidates.Count; $i++) { Invoke-Candidate $Candidates[$i] }
  }

  $Ranked = @($Rows | Sort-Object -Property `
    @{Expression={[double]$_.total};Descending=$true}, `
    @{Expression={[double]$_.nodes_avg};Ascending=$true}, `
    @{Expression={[double]$_.focus_perf};Descending=$true})
  Write-Host ""
  Write-Host '### ranked: official total desc, nodes asc, focused perf desc'
  $Ranked | Format-Table name,min,max,target,focus_perf,min_avail,nodes_avg,total -AutoSize | Out-String | Write-Host
  $Winner = $Ranked[0]
  Set-HpaState $App $Winner.min $Winner.max $Winner.target
  Write-Host "### WINNER applied: $App min=$($Winner.min) max=$($Winner.max) target=$($Winner.target)% total=$($Winner.total)/36" -ForegroundColor Green
  Write-Host "### Terraform 반영: k8s_apps.tf 의 $App HPA min_replicas=$($Winner.min), max_replicas=$($Winner.max), average_utilization=$($Winner.target)"
  if ($DrainSeconds -eq 0) {
    Write-Warning 'DrainSeconds=0: 이전 후보가 만든 노드가 다음 후보 비용에 남을 수 있습니다. 최종 후보를 180s로 한 번 더 검증하세요.'
  }
  Write-Host "results: $ResultsPath"
}
catch {
  Write-Error $_
  Write-Warning "실패했으므로 원래 HPA로 복원합니다: $($Original.min)/$($Original.max)/$($Original.target)"
  Set-HpaState $App $Original.min $Original.max $Original.target
  exit 1
}
