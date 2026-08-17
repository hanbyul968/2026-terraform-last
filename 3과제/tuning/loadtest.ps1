<#
  채점기 스타일 부하 테스트 (loadtest.sh 의 PowerShell 판). config.ps1 을 dot-source 한다.
  API 목록/SLO/부하 모양은 config.ps1 에서 읽으므로 대회 앱이 바뀌어도 config 만 고치면 된다.

  사용법:
    .\loadtest.ps1 <endpoint> [duration 예: 180s] [label]

  각 API 를 채점처럼 측정: 가용성(5초 내 2xx) + 성능(응답시간 <= API별 SLO), 노드 수 타임라인.
#>
[CmdletBinding()]
param(
  [string]$Duration = '180s',
  [string]$Label = 'run',
  [string]$Url = ''   # 비우면 config.ps1 의 $ENDPOINT 사용 (-Url 로 이 실행만 override)
)
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

# ~/bin 을 PATH 앞에 (hey/kubectl)
$bin = Join-Path $env:USERPROFILE 'bin'
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }

if (-not $Url) { $Url = $ENDPOINT }
if (-not $Url -or $Url -like '*REPLACE-ME*') {
  Write-Error 'endpoint 미설정 — config.ps1 의 $ENDPOINT 를 채우거나 -Url http://... 로 전달'; exit 1
}
$EP = $Url.TrimEnd('/')

# --- 사전 점검: 엔드포인트가 실제로 응답하나? (죽은/옛 주소면 여기서 바로 드러남) ---
$probe = '000'
try { $probe = (curl.exe -s -o NUL -w "%{http_code}" --max-time 5 "$EP/healthcheck" 2>$null) } catch {}
Write-Host ("  endpoint: {0}   (healthcheck {1})" -f $EP, $probe) -ForegroundColor Cyan
if ($probe -notmatch '^(2|3)\d\d$') {
  Write-Warning ("엔드포인트가 응답하지 않습니다 (코드 $probe). 죽은/옛 주소이거나 스택 미배포일 수 있어요.")
  Write-Warning ("현재 주소 확인:  cd ..\terraform ; terraform output -raw endpoint")
  Write-Warning ("그 주소로 다시:  .\loadtest.ps1 -Url http://<맞는주소> -Duration $Duration -Label $Label")
  # 그래도 진행은 함(사용자가 의도적으로 다른 경로를 볼 수도 있으니). NO DATA 나오면 위 경고가 원인.
}

$OUT = Join-Path $env:TEMP "tune-$Label"
New-Item -ItemType Directory -Force -Path $OUT | Out-Null
# 이전 실행 결과를 반드시 지운다. nodes.csv / podcpu.csv 는 Add-Content(append) 로 쓰므로
# 같은 -Label 로 다시 돌리면 옛 표본이 그대로 쌓인다.
#   실측 사고: autotune 의 조합 이름(baseline, lean-cpu, ...)이 과거 실행 라벨과 같아
#   tune-baseline/nodes.csv 에 35일치 3423 표본이 누적됐고, 그 평균으로 비용 비율을
#   계산해 실제와 다른 값이 나왔다(조합 간 비교도 무의미해진다).
# 앱 CSV(<앱>.csv)는 Out-File 로 덮어쓰므로 문제가 없지만, 옛 앱이 남아 있으면
# 그것도 앱으로 잡히니(예: 대회날 앱 이름이 바뀐 경우) 함께 정리한다.
Get-ChildItem -Path $OUT -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in '.csv', '.err', '.json' } |
  Remove-Item -Force -ErrorAction SilentlyContinue

$Hey = (Get-Command hey -ErrorAction SilentlyContinue).Source
$Kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $Hey) { Write-Error 'hey 없음 — 먼저 .\setup.ps1 <cluster> <region> 실행'; exit 1 }
if (-not $Kubectl) { Write-Warning 'kubectl 없음 — 노드 샘플링 생략(가용성/성능은 정상 측정)' }

# --- node/pod 샘플러 (5초 간격, 백그라운드 잡) ---
# nodes.csv  : ts,노드수,Running파드수      (비용 지표 = 노드 수 평균)
# podcpu.csv : ts,파드명,cpu(밀리코어)      (loadwindows와 결합해 request 후보 산정)
#
# podcpu.csv 를 반드시 부하 '중에' 남겨야 하는 이유:
#   request 후보는 활성 부하 창의 같은 시각 총CPU/파드수에서 나온다. 부하가 끝난 뒤 한 번
#   찍으면 그 순간값이 피크로 잡힌다. 스파이크 순간에 찍히면 과대(실측: 실사용 132m 인데
#   400m 로 읽혀 request 300m 를 권고), 부하가 빠진 뒤에 찍히면 과소가 된다.
#   5초 간격으로 창 전체를 남겨 두면 p95/최대를 제대로 계산할 수 있다.
$sampler = $null
if ($Kubectl) {
  $sampler = Start-Job -ScriptBlock {
    param($NS, $csv, $cpucsv, $nodecpucsv, $kubectl)
    while ($true) {
      # Get-Date -UFormat %s 는 Windows PowerShell 5.1에서 로컬 UTC+9를 한 번 더
      # 더해 Unix epoch가 9시간 어긋났다. loadwindows.csv와 같은 UTC epoch를 쓴다.
      $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      # kubectl 조회가 실패했을 때 0 을 기록하면 안 된다. 노드가 0대인 상황은 없으므로
      # 그 0 은 '측정 실패'인데, 평균에 섞이면 비용 지표(평균 노드 수)를 실제보다
      # 좋게 만든다. 실측 사고: 3399 표본 중 1370개(40%)가 0 이었고 그 결과
      # 평균 2.28대(ratio 1.14, 비용 11점)로 보였지만, 0 을 제외하면 3.82대
      # (ratio 1.91, 비용 9점)였다. 실패한 표본은 아예 남기지 않는다.
      $n = $null; $p = $null
      try { $n = (& $kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch {}
      try { $p = (& $kubectl -n $NS get pods --no-headers 2>$null | Select-String 'Running').Count } catch {}
      if ($n -ge 1) { "$ts,$n,$(if ($p -ne $null) { $p } else { 0 })" | Add-Content -Path $csv }
      # 노드 CPU도 부하 창에 기록한다. 부하가 끝난 뒤 kubectl top nodes 1회로
      # 포화 여부를 판단하면 이미 1~2%로 내려가 request 판정이 뒤집힌다.
      try {
        $nodeRows = & $kubectl top nodes --no-headers 2>$null
        foreach ($r in $nodeRows) {
          $f = ($r -split '\s+') | Where-Object { $_ -ne '' }
          if ($f.Count -ge 3 -and $f[2] -match '^(\d+)%$') {
            "$ts,$($f[0]),$([int]$Matches[1])" | Add-Content -Path $nodecpucsv
          }
        }
      } catch {}
      # 파드별 CPU 실사용. metrics-server 가 없으면 조용히 건너뛴다(가용성/성능 측정엔 무관).
      try {
        $rows = & $kubectl -n $NS top pods --no-headers 2>$null
        foreach ($r in $rows) {
          $f = ($r -split '\s+') | Where-Object { $_ -ne '' }
          if ($f.Count -ge 2) {
            $c = $f[1]
            $m = if ($c -match '^(\d+)m$') { [int]$Matches[1] } else { [int]([double]$c * 1000) }
            "$ts,$($f[0]),$m" | Add-Content -Path $cpucsv
          }
        }
      } catch {}
      Start-Sleep -Seconds 5
    }
  } -ArgumentList $NS, (Join-Path $OUT 'nodes.csv'), (Join-Path $OUT 'podcpu.csv'), (Join-Path $OUT 'nodecpu.csv'), $Kubectl
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
# hey 의 -q 는 전체 QPS가 아니라 "worker 1개당 QPS"다. 따라서 키 분산 때 -q를
# 키 수로 나누면 안 된다. 총 부하는 sum(c_i * q) = 원래 conc * q 여야 한다.
#
# 또한 키마다 Start-Job을 만들면 Windows PowerShell의 프로세스 잡 시작 지연 때문에
# 20개 키가 여러 wave로 실행된다. 실측: -z 180s인데 마지막 요청 offset이 475s였고,
# 뒤쪽 podcpu 표본은 이미 부하가 끝난 앱의 1m 유휴값이었다. Start-Process로 hey.exe를
# 직접 동시에 띄워 이 지연을 없앤다.
function Convert-DurationSeconds([string]$d) {
  if ($d -match '^(\d+(?:\.\d+)?)(ms|s|m|h)$') {
    $n = [double]$Matches[1]
    switch ($Matches[2]) {
      'ms' { return $n / 1000.0 }
      's'  { return $n }
      'm'  { return $n * 60.0 }
      'h'  { return $n * 3600.0 }
    }
  }
  throw "Duration 형식 오류: $d (예: 180s, 3m)"
}

$durationSec = Convert-DurationSeconds $Duration
$procs = @()
$plans = @()
$windows = @{}
foreach ($a in $APIS) {
  $bodyFile = ''
  if ($a.method -ne 'GET' -and $a.body) {
    $bodyFile = Join-Path $OUT "$($a.name).body.json"
    $a.body | Set-Content -Path $bodyFile -Encoding ascii -NoNewline
  }

  # Hashtable에는 원래 .Keys 속성이 있다. API에 'keys' 항목이 없는 stress에서
  # $a.keys를 읽으면 null이 아니라 name/slo/conc/... 7개 필드명이 나와 stress를 7배
  # 복제하는 버그가 생긴다. 반드시 ContainsKey + 인덱서로 구분한다.
  $hasRequestKeys = $a.ContainsKey('keys') -and $null -ne $a['keys'] -and @($a['keys']).Count -gt 0
  $allKeys = if ($hasRequestKeys) { @($a['keys']) } else { @('__TUNE_NO_KEY__') }
  # 동시성보다 process를 많이 만들면 c=0이 생긴다. 최대 conc개 키만 쓴다.
  $jobCount = [math]::Min($allKeys.Count, [int]$a.conc)
  $keyList = @($allKeys | Select-Object -First $jobCount)
  $baseC = [math]::Floor([int]$a.conc / $jobCount)
  $extraC = [int]$a.conc % $jobCount
  $qWorker = $a.qps   # hey -q는 worker당 QPS — 절대 키 수로 나누지 않는다.
  $expectedQps = if ($qWorker) { [double]$a.conc * [double]$qWorker } else { 0 }
  $plans += [pscustomobject]@{
    name = $a.name; duration_seconds = $durationSec; concurrency = $a.conc
    qps_per_worker = $qWorker; expected_qps = $expectedQps
    expected_requests = [math]::Round($expectedQps * $durationSec); jobs = $jobCount
  }
  $windows[$a.name] = [pscustomobject]@{ start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); duration = $durationSec }

  for ($i = 0; $i -lt $jobCount; $i++) {
    $key = $keyList[$i]
    $cThis = [int]$baseC + $(if ($i -lt $extraC) { 1 } else { 0 })
    $pathForKey = if ($hasRequestKeys -and $a.pathFmt) { $a.pathFmt.Replace('{KEY}', $key) } else { $a.path }
    $part = $i + 1
    # PowerShell 변수명은 대소문자를 구분하지 않는다. $out 을 쓰면 결과 폴더 $OUT 을
    # 덮어써 다음 경로가 user.part1.csv\user.part2.csv... 로 망가진다.
    $stdoutPath = Join-Path $OUT "$($a.name).part$part.csv"
    $stderrPath = Join-Path $OUT "$($a.name).part$part.err"
    $heyArgs = @('-z', $Duration, '-c', "$cThis")
    if ($qWorker) { $heyArgs += @('-q', "$qWorker") }
    if ($a.method -ne 'GET') {
      $heyArgs += @('-m', $a.method, '-T', 'application/json', '-D', $bodyFile)
    }
    $heyArgs += @('-o', 'csv', "$EP$pathForKey")
    $proc = Start-Process -FilePath $Hey -ArgumentList $heyArgs -NoNewWindow `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $procs += [pscustomobject]@{ app = $a.name; process = $proc }
  }
}

# 실제 계획을 남겨 advise.py가 부하량과 CPU 활성 창을 검증할 수 있게 한다.
$plans | Export-Csv -Path (Join-Path $OUT 'loadplan.csv') -NoTypeInformation -Encoding ascii
$procs.process | Wait-Process
$windowRows = foreach ($name in $windows.Keys) {
  $w = $windows[$name]
  [pscustomobject]@{ name = $name; start_epoch = $w.start; active_end_epoch = $w.start + [math]::Ceiling($w.duration) }
}
$windowRows | Export-Csv -Path (Join-Path $OUT 'loadwindows.csv') -NoTypeInformation -Encoding ascii

# 키별 부분 결과를 <앱>.csv 하나로 합친다. hey CSV 는 첫 줄이 헤더이므로 헤더는 한 번만 쓴다.
foreach ($a in $APIS) {
  $parts = Get-ChildItem -Path $OUT -Filter "$($a.name).part*.csv" -File -ErrorAction SilentlyContinue |
           Sort-Object Name
  if (-not $parts) { continue }
  $merged = Join-Path $OUT "$($a.name).csv"
  $wroteHeader = $false
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($f in $parts) {
    $raw = Get-Content -Path $f.FullName -ErrorAction SilentlyContinue
    if (-not $raw) { continue }
    $i = 0
    foreach ($ln in $raw) {
      if ($i -eq 0) {
        if (-not $wroteHeader) { $lines.Add($ln); $wroteHeader = $true }
      } elseif ($ln.Trim()) {
        $lines.Add($ln)
      }
      $i++
    }
  }
  if ($lines.Count -gt 0) {
    [System.IO.File]::WriteAllLines($merged, $lines)
    $parts | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $OUT -Filter "$($a.name).part*.err" -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

if ($sampler) { Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue }

# --- 채점 (SLO 는 config.ps1 의 $SLOS) ---
python (Join-Path $Here 'score.py') report $OUT $Label $SLOS

# --- 권장값 + 복붙 명령 (측정 → 앱별 늘려/줄여/유지 판정) ---
python (Join-Path $Here 'advise.py') $OUT --slos $SLOS --ns $NS
