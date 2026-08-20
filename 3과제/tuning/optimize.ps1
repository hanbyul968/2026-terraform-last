<#
  공식 채점 총점을 최대화하는 18분 라이브 튜닝 루프.
  warmup -> baseline -> 후보(최대3) 적용 -> 120초 측정 -> 채택/롤백.
  Terraform은 건드리지 않는다. request 변경은 rollout을 동반하므로 공식 트래픽 전에 실행한다.
#>
[CmdletBinding()]
param(
  [int]$BudgetMinutes = 18,
  [string]$Duration = '120s',
  [int]$WarmupSeconds = 60,
  [int]$Iterations = 3,
  [int]$SettleSeconds = 25,
  [int]$CostSettleSeconds = 105,
  [switch]$Apply,
  [string]$Url = ''
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')
foreach ($tool in 'kubectl','hey') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool 없음 — setup.ps1 먼저 실행" }
}
$py = if (Get-Command py -ErrorAction SilentlyContinue) { @((Get-Command py).Source,'-3') }
      elseif (Get-Command python -ErrorAction SilentlyContinue) { @((Get-Command python).Source) }
      else { throw 'Python 없음' }

function Invoke-Py { param([string[]]$PyArgs)
  $env:PYTHONIOENCODING='utf-8'; $old=[Console]::OutputEncoding
  try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false); & $py[0] @($py[1..($py.Count-1)]) @PyArgs }
  finally { [Console]::OutputEncoding=$old }
}
function Get-Score { param([string]$OutDir)
  $raw=Invoke-Py @((Join-Path $Here 'score.py'),'score',$OutDir,$SLOS,"$AVAIL_GATE","$COST_PENALTY")
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}
function Get-NextStep { param([string]$OutDir,[string]$RejFile)
  $a=@((Join-Path $Here 'optimize.py'),$OutDir,'--slos',$SLOS,'--ns',$NS,'--avail-gate',"$AVAIL_GATE",'--json')
  if($RejFile){$a+=@('--rejected',$RejFile)}
  $raw=Invoke-Py $a; return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}
function Get-LiveRequest { param([string]$App)
  $v=& kubectl -n $NS get deploy $App -o 'jsonpath={.spec.template.spec.containers[0].resources.requests.cpu}' 2>$null
  if("$v" -match '^(\d+)m$'){return [int]$Matches[1]}
  if("$v" -match '^\d+(\.\d+)?$'){return [int]([double]$v*1000)}
  return 0
}
function Set-Tuning { param([string]$App,$Knob)
  $hpa=if($Knob.hpa_name){[string]$Knob.hpa_name}else{$App}
  $deployment=if($Knob.deployment_name){[string]$Knob.deployment_name}else{$App}
  $body=@{spec=@{minReplicas=[int]$Knob.min;maxReplicas=[int]$Knob.max;metrics=@(@{type='Resource';resource=@{name='cpu';target=@{type='Utilization';averageUtilization=[int]$Knob.target}}})}}
  $f=Join-Path $env:TEMP "hpa-$App.json"; ($body|ConvertTo-Json -Depth 10 -Compress)|Set-Content $f -Encoding ascii
  & kubectl -n $NS patch hpa $hpa --type=merge --patch-file $f | Out-Null
  $wanted=[int]$Knob.request; $live=Get-LiveRequest $deployment
  if($wanted -gt 0 -and $wanted -ne $live){
    & kubectl -n $NS set resources "deploy/$deployment" "--requests=cpu=$($wanted)m" | Out-Null
    & kubectl -n $NS rollout status "deploy/$deployment" --timeout=120s | Out-Null
  }
}
function Write-Rejected { param($Rows,[string]$Path)
  $items=@($Rows|ForEach-Object{$_|ConvertTo-Json -Compress}); ('['+($items -join ',')+']')|Set-Content $Path -Encoding ascii
}

if(-not $Url){$Url=$ENDPOINT}
$loadtest=Join-Path $Here 'loadtest.ps1'
$ltArgs=@{Duration=$Duration;Label='opt'};if($Url){$ltArgs.Url=$Url}

function ConvertTo-DurationSeconds { param([string]$Value)
  if($Value -notmatch '^(\d+(?:\.\d+)?)(ms|s|m|h)$'){throw "Duration 형식 오류: $Value (예: 120s, 2m)"}
  $n=[double]$Matches[1]
  switch($Matches[2]){'ms'{return $n/1000};'s'{return $n};'m'{return $n*60};'h'{return $n*3600}}
}

$sw=[Diagnostics.Stopwatch]::StartNew();$deadline=[TimeSpan]::FromMinutes($BudgetMinutes)
$candidateLimit=[Math]::Min([Math]::Max($Iterations,0),3)
$rejFile=Join-Path $env:TEMP 'optimize-rejected.json';'[]'|Set-Content $rejFile -Encoding ascii
$rejected=@();$pending=$null;$bestKnobs=$null
Write-Host '=== 공식 채점기준 라이브 튜닝 ===' -ForegroundColor Cyan
Write-Host ("예산 {0}분 / warmup {1}s / 측정 {2} / 후보 최대 {3}개" -f $BudgetMinutes,$WarmupSeconds,$Duration,$candidateLimit)

try {
  if($Apply -and $WarmupSeconds -gt 0){
    $warm=@{Duration=("{0}s" -f $WarmupSeconds);Label='opt-warm'};if($Url){$warm.Url=$Url}
    Write-Host "워밍업 $WarmupSeconds 초(점수 제외)..." -ForegroundColor DarkGray
    & $loadtest @warm | Out-Null
  }
  & $loadtest @ltArgs | Out-Null
  $out=Join-Path $env:TEMP 'tune-opt';$bestScore=Get-Score $out;$first=Get-NextStep $out $null
  $bestKnobs=$first.knobs
  Write-Host ("[baseline] {0:N1}/36 ratio={1:N2} elapsed={2:N1}m" -f $bestScore.total,$bestScore.cost_ratio,$sw.Elapsed.TotalMinutes)
  if(-not $Apply){
    if($first.done){Write-Host "수렴: $($first.reason)" -ForegroundColor Green}
    else{Write-Host ("후보 [{0}] {1}: request={2}m target={3}% min={4} max={5}" -f $first.kind,$first.app,$first.knob.request,$first.knob.target,$first.knob.min,$first.knob.max) -ForegroundColor Green;Write-Host $first.reason}
    return
  }
  for($i=1;$i -le $candidateLimit;$i++){
    $step=Get-NextStep $out $rejFile
    if($step.done){Write-Host "수렴: $($step.reason)" -ForegroundColor Green;break}
    $candidate=$step.candidate;$settle=[int]$candidate.settle_seconds
    if($step.kind -eq 'cost-reclaim'){$settle=[Math]::Max($settle,$CostSettleSeconds)}elseif(-not $candidate.disruptive){$settle=[Math]::Max($settle,$SettleSeconds)}
    $durationSec=ConvertTo-DurationSeconds $Duration
    # request rollback은 rollout까지 필요하므로 150초를 항상 예약한다.
    $required=[TimeSpan]::FromSeconds($settle+$durationSec+150)
    if($sw.Elapsed+$required -ge $deadline){Write-Host '남은 예산이 측정+롤백 시간보다 짧아 종료' -ForegroundColor Yellow;break}
    $app=$step.app;$pending=$app
    Write-Host ("--- {0}/{1} [{2}] {3}: request {4}->{5}m target {6}->{7}% nodes {8} (CPU하한 {9})" -f $i,$candidateLimit,$step.kind,$app,$candidate.current.request,$candidate.proposed.request,$candidate.current.target,$candidate.proposed.target,$candidate.predicted_nodes,$candidate.observed_cpu_floor)
    Set-Tuning $app $step.knob
    Start-Sleep -Seconds $settle
    & $loadtest @ltArgs | Out-Null
    $score=Get-Score $out
    $gate=$score.perf_gate_pass -and $score.avail_gate_pass
    # 99% availability/30% performance는 점수보다 우선하는 hard gate다.
    # 공식 band 점수가 동률이어도 gate 방향으로 개선되면 채택해 다음 복구 수를 허용한다.
    $availImproved=(-not $bestScore.avail_gate_pass) -and ($score.min_avail -gt $bestScore.min_avail) -and ($score.min_perf -ge $bestScore.min_perf)
    $perfImproved=(-not $bestScore.perf_gate_pass) -and ($score.min_perf -gt $bestScore.min_perf) -and ($score.min_avail -ge $bestScore.min_avail)
    $safetyImproved=$availImproved -or $perfImproved
    if($safetyImproved -or ($gate -and $score.total -gt $bestScore.total)){
      Write-Host ("채택 {0:N1}->{1:N1}, ratio={2:N2}, safetyImproved={3}" -f $bestScore.total,$score.total,$score.cost_ratio,$safetyImproved) -ForegroundColor Green
      $bestScore=$score;$bestKnobs.$app=$step.knob;$pending=$null
    }else{
      Write-Host ("거절 score={0:N1} gate={1}; snapshot 롤백" -f $score.total,$gate) -ForegroundColor Yellow
      Set-Tuning $app $bestKnobs.$app;$pending=$null
      $rejected+=@{key=$candidate.key;app=$app;kind=$step.kind};Write-Rejected $rejected $rejFile
    }
  }
  Write-Host ("`n=== 종료 {0:N1}분 / best {1:N1}/36 ratio={2:N2} ===" -f $sw.Elapsed.TotalMinutes,$bestScore.total,$bestScore.cost_ratio) -ForegroundColor Green
  if(-not ($bestScore.perf_gate_pass -and $bestScore.avail_gate_pass)){
    Write-Warning ("안전 게이트 미복구: min availability={0:N1}% / min performance={1:N1}%. 이 상태로 공식 트래픽을 시작하지 마세요." -f $bestScore.min_avail,$bestScore.min_perf)
  }
  foreach($name in $bestKnobs.PSObject.Properties.Name|Sort-Object){$k=$bestKnobs.$name;Write-Host ('{0}: requests.cpu="{1}m", min_replicas={2}, max_replicas={3}, average_utilization={4}' -f $name,$k.request,$k.min,$k.max,$k.target)}
  Write-Host '현재 값은 라이브 적용 상태입니다. Terraform apply는 튜닝 흐름에 필요하지 않습니다.'
}
finally {
  if($pending -and $bestKnobs -and $bestKnobs.$pending){
    Write-Warning "중단 감지: $pending 을 마지막 채택 snapshot으로 롤백"
    try{Set-Tuning $pending $bestKnobs.$pending}catch{Write-Warning "자동 롤백 실패: $_"}
  }
}
