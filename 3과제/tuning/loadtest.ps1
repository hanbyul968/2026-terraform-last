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

$Hey = (Get-Command hey -ErrorAction SilentlyContinue).Source
$Kubectl = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
if (-not $Hey) { Write-Error 'hey 없음 — 먼저 .\setup.ps1 <cluster> <region> 실행'; exit 1 }
if (-not $Kubectl) { Write-Warning 'kubectl 없음 — 노드 샘플링 생략(가용성/성능은 정상 측정)' }

# --- node/pod 샘플러 (5초 간격, 백그라운드 잡) ---
# nodes.csv  : ts,노드수,Running파드수      (비용 지표 = 노드 수 평균)
# podcpu.csv : ts,파드명,cpu(밀리코어)      (request 산정의 유일한 근거)
#
# podcpu.csv 를 반드시 부하 '중에' 남겨야 하는 이유:
#   request 권장값은 실사용 피크에서 나온다. 그런데 부하가 끝난 뒤 kubectl top 을 한 번
#   찍으면 그 순간값이 피크로 잡힌다. 스파이크 순간에 찍히면 과대(실측: 실사용 132m 인데
#   400m 로 읽혀 request 300m 를 권고), 부하가 빠진 뒤에 찍히면 과소가 된다.
#   5초 간격으로 창 전체를 남겨 두면 p95/최대를 제대로 계산할 수 있다.
$sampler = $null
if ($Kubectl) {
  $sampler = Start-Job -ScriptBlock {
    param($NS, $csv, $cpucsv, $kubectl)
    while ($true) {
      $ts = [int][double]::Parse((Get-Date -UFormat %s))
      # kubectl 조회가 실패했을 때 0 을 기록하면 안 된다. 노드가 0대인 상황은 없으므로
      # 그 0 은 '측정 실패'인데, 평균에 섞이면 비용 지표(평균 노드 수)를 실제보다
      # 좋게 만든다. 실측 사고: 3399 표본 중 1370개(40%)가 0 이었고 그 결과
      # 평균 2.28대(ratio 1.14, 비용 11점)로 보였지만, 0 을 제외하면 3.82대
      # (ratio 1.91, 비용 9점)였다. 실패한 표본은 아예 남기지 않는다.
      $n = $null; $p = $null
      try { $n = (& $kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch {}
      try { $p = (& $kubectl -n $NS get pods --no-headers 2>$null | Select-String 'Running').Count } catch {}
      if ($n -ge 1) { "$ts,$n,$(if ($p -ne $null) { $p } else { 0 })" | Add-Content -Path $csv }
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
  } -ArgumentList $NS, (Join-Path $OUT 'nodes.csv'), (Join-Path $OUT 'podcpu.csv'), $Kubectl
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
  # POST body 는 부모에서 미리 파일로 저장한다.
  #  - 이유1(따옴표): Windows 는 따옴표 JSON 을 네이티브 exe 에 '-d $body' 로 넘기면 깨져 400(invalid body).
  #  - 이유2(레이스): Start-Job 안에서 파일을 쓰면 병렬 실행 시 stress 만 body 파일이 안 만들어지는 문제가 있음.
  #  → 부모에서 파일로 쓰고 hey '-D <file>' 로 원문 그대로 전송.
  $bodyFile = ''
  if ($a.method -ne 'GET' -and $a.body) {
    $bodyFile = Join-Path $OUT "$($a.name).body.json"
    $a.body | Set-Content -Path $bodyFile -Encoding ascii -NoNewline
  }
  $jobs += Start-Job -ScriptBlock {
    param($hey, $dur, $a, $EP, $OUT, $bodyFile)
    $out = Join-Path $OUT "$($a.name).csv"
    $err = Join-Path $OUT "$($a.name).err"
    # ⚠ Start-Job 안에서 네이티브 exe(hey)의 stdout 을 '> $out' 로 파일 리다이렉트하면
    #    출력이 통째로 사라져 0바이트 CSV → 채점기가 "NO DATA" 가 되는 버그가 있음.
    #    → stdout 을 변수로 캡처($r)한 뒤 Out-File 로 기록해야 안정적으로 저장된다.
    $url = "$EP$($a.path)"
    if ($a.method -eq 'GET') {
      $r = & $hey -z $dur -c $a.conc -q $a.qps -o csv $url 2>&1
    } else {
      $r = & $hey -z $dur -c $a.conc -q $a.qps -m $a.method -T application/json -D $bodyFile -o csv $url 2>&1
    }
    # ErrorRecord(진짜 에러)는 .err 로, 나머지(CSV 본문)는 .csv 로 분리 저장.
    $r | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Out-File -FilePath $err -Encoding ascii
    $r | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-File -FilePath $out -Encoding ascii
  } -ArgumentList $Hey, $Duration, $a, $EP, $OUT, $bodyFile
}
Wait-Job $jobs | Out-Null
Remove-Job $jobs

if ($sampler) { Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue }

# --- 채점 (SLO 는 config.ps1 의 $SLOS) ---
python (Join-Path $Here 'score.py') report $OUT $Label $SLOS

# --- 권장값 + 복붙 명령 (측정 → 앱별 늘려/줄여/유지 판정) ---
python (Join-Path $Here 'advise.py') $OUT --slos $SLOS --ns $NS
