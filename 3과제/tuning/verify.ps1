<#
  채점 1번 항목(비정상 요청 처리 4점) + 엔드포인트 규약 검증기.

  loadtest.ps1 은 user/product/stress 의 가용성·성능(2·3번 항목, 24점)만 측정한다.
  1번 항목(image download 4점 중 2점 / Exception Handling 2점)은 부하가 아니라
  "응답코드가 규약대로 나오는가"이므로 이 스크립트로 따로 확인한다.

  검증 항목
    A. 정상 요청        → 2xx            (여기서 깨지면 avail% 도 같이 죽는다)
    B. 유효 경로 비정상 → 403            (문제지: 비정상 요청은 Block + 403)
    C. 미정의 경로      → 404            (문제지: 제공 API 외 요청은 404)
    D. 이미지 다운로드  → 200 + 본문 일치 (S3 에 프로브 오브젝트를 넣고 CloudFront 경유 GET)
    E. CloudFront 우회  → 403            (ALB 직접 호출 차단 확인, 정보성)

  사용법:
    .\verify.ps1                 # config.ps1 의 엔드포인트
    .\verify.ps1 -Url http://... # 주소 지정
    .\verify.ps1 -SkipImage      # S3 프로브 없이 (자격증명/버킷 조회 불가할 때)

  종료코드: 실패 항목이 있으면 1 (CI/반복 확인용)
#>
[CmdletBinding()]
param(
  [string]$Url = '',
  [switch]$SkipImage
)
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

if (-not $Url) { $Url = $ENDPOINT }
if (-not $Url) {
  Write-Error 'endpoint 미설정 — cd ..\terraform ; terraform output -raw endpoint 확인 후 -Url 로 전달'
  exit 1
}
$EP = $Url.TrimEnd('/')

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Test-Code {
  param(
    [string]$Name,
    [string]$Expect,      # '2xx' | '403' | '404' ...
    [string[]]$CurlArgs
  )
  $code = '000'
  try { $code = (& curl.exe -s -o NUL -w "%{http_code}" --max-time 10 @CurlArgs 2>$null) } catch {}
  $ok = if ($Expect -eq '2xx') { $code -match '^2\d\d$' } else { $code -eq $Expect }
  if ($ok) {
    $script:Pass++
    Write-Host ("  [OK]   {0,-46} {1}" -f $Name, $code) -ForegroundColor Green
  } else {
    $script:Fail++
    Write-Host ("  [FAIL] {0,-46} {1} (기대 {2})" -f $Name, $code, $Expect) -ForegroundColor Red
  }
}

Write-Host ""
Write-Host "=== verify: $EP ===" -ForegroundColor Cyan

# ---------- 시드: A 그룹의 GET 대상 레코드를 먼저 만든다 ----------
# config.ps1 의 $APIS 는 GET 경로에 특정 레코드(loadseed1 / loadseedp1)를 지정한다.
# 그 레코드가 없으면 앱이 정상이어도 조회가 404 라서 [FAIL] 로 보인다.
# loadtest.ps1 은 부하 전에 $SEEDS 를 넣는데 verify 는 안 넣어서 생기던 오탐.
# 이미 있으면 중복 응답(4xx)이 오지만 무시한다 — 목적은 "행이 존재함" 뿐이다.
if ($SEEDS -and $SEEDS.Count -gt 0) {
  Write-Host "  시드 레코드 준비 ($($SEEDS.Count)건)..." -ForegroundColor DarkGray
  foreach ($s in $SEEDS) {
    if ($s.method -eq 'GET') {
      & curl.exe -s -o NUL --max-time 10 "$EP$($s.path)" 2>$null | Out-Null
    } else {
      $sf = Join-Path $env:TEMP "verify-seed-$([Math]::Abs($s.path.GetHashCode())).json"
      $s.body | Set-Content -Path $sf -Encoding ascii -NoNewline
      & curl.exe -s -o NUL --max-time 10 -X $s.method -H 'Content-Type: application/json' `
        --data-binary "@$sf" "$EP$($s.path)" 2>$null | Out-Null
    }
  }
  Start-Sleep -Seconds 1   # product GET 은 CloudFront 캐싱이 걸려 있어 잠깐 여유
}

# ---------- A. 정상 요청 ----------
Write-Host ""
Write-Host "A. 정상 요청 (2xx)" -ForegroundColor White
Test-Code 'GET healthcheck' '2xx' @("$EP$HC_PATH")

# config.ps1 의 API 는 두 형태를 가질 수 있다:
#   path    : 완성된 경로 (예: stress)
#   pathFmt + keys : {KEY} 자리에 키를 넣어 쓰는 형태 (부하를 여러 키로 분산하기 위함)
# verify 는 '응답코드 규약' 만 보므로 키 하나만 쓰면 된다. 첫 키로 경로를 만든다.
# (이 헬퍼가 없으면 pathFmt 만 있는 API 에서 경로가 빈 문자열이 되어 전부 404 가 된다)
function Get-ApiPath($a) {
  if ($a.path) { return $a.path }
  if ($a.pathFmt) {
    $k = if ($a.keys -and $a.keys.Count -gt 0) { $a.keys[0] } else { '' }
    return $a.pathFmt.Replace('{KEY}', $k)
  }
  return ''
}

foreach ($a in $APIS) {
  if ($a.method -eq 'GET') {
    Test-Code "GET $($a.name)" '2xx' @("$EP$(Get-ApiPath $a)")
  } else {
    $bf = Join-Path $env:TEMP "verify-$($a.name).json"
    $a.body | Set-Content -Path $bf -Encoding ascii -NoNewline
    Test-Code "$($a.method) $($a.name)" '2xx' @('-X', $a.method, '-H', 'Content-Type: application/json', '--data-binary', "@$bf", "$EP$(Get-ApiPath $a)")
  }
}

# ---------- B. 유효 경로 + 비정상 요청 → 403 ----------
# 대상 경로는 config.ps1 의 APIS 에서 가져온다 (스펙이 바뀌면 config 만 고치면 됨).
$validPath = Get-ApiPath (($APIS | Where-Object { $_.method -eq 'GET' } | Select-Object -First 1))
if (-not $validPath) { $validPath = Get-ApiPath $APIS[0] }

Write-Host ""
Write-Host "B. 유효 경로 + 비정상 요청 (403)" -ForegroundColor White
Test-Code 'scanner UA (sqlmap)'      '403' @('-A', 'sqlmap/1.7', "$EP$validPath")
Test-Code 'junk header (X-Junk)'     '403' @('-H', 'X-Junk: 1', "$EP$validPath")
Test-Code 'forged XFF (127.0.0.1)'   '403' @('-H', 'X-Forwarded-For: 127.0.0.1', "$EP$validPath")
Test-Code 'path traversal in query'  '403' @("$EP$validPath&f=/etc/passwd")
$injBody = Join-Path $env:TEMP 'verify-inj.json'
'{"requestid":"1","uuid":"u","username":{"$ne":null},"email":"x@x.org"}' | Set-Content -Path $injBody -Encoding ascii -NoNewline
# POST 대상도 config 에서 유도 (api_prefix 가 /v2 로 바뀌어도 따라간다).
$postTarget = (Get-ApiPath ($APIS | Select-Object -First 1)) -replace '\?.*$', ''
Test-Code 'NoSQL injection body'     '403' @('-X', 'POST', '-H', 'Content-Type: application/json', '--data-binary', "@$injBody", "$EP$postTarget")

# ---------- C. 미정의 경로 → 404 ----------
Write-Host ""
Write-Host "C. 미정의 경로 (404 — 403 이면 오답)" -ForegroundColor White
foreach ($p in @('/v1/none', '/.env', '/admin', '/v1/users')) {
  Test-Code "GET $p" '404' @("$EP$p")
}

# ---------- D. 이미지 다운로드 ----------
Write-Host ""
Write-Host "D. 이미지 다운로드 (S3 -> CloudFront, 200)" -ForegroundColor White
if ($SkipImage) {
  $script:Skip++
  Write-Host '  [SKIP] -SkipImage 지정' -ForegroundColor Yellow
} else {
  $bucket = ''
  $tfdir = Join-Path $Here '..\terraform'
  if (Test-Path $tfdir) {
    Push-Location $tfdir
    try { $bucket = (terraform output -raw s3_bucket 2>$null) } catch {}
    Pop-Location
  }
  if (-not $bucket) {
    $script:Skip++
    Write-Host '  [SKIP] 버킷 조회 실패 (terraform output s3_bucket)' -ForegroundColor Yellow
  } else {
    # 키를 매 실행마다 유니크하게 만든다. 고정 키(verify-probe.txt)를 쓰면 images 캐시
    # 정책의 default_ttl(1일) 때문에 CloudFront 가 이전 실행의 본문을 그대로 돌려주고,
    # S3 원본을 새로 올려도 body 비교가 실패한다(200 은 뜨므로 더 헷갈린다).
    $marker = "verify-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $key = "$marker.txt"
    $probe = Join-Path $env:TEMP $key
    $marker | Set-Content -Path $probe -Encoding ascii -NoNewline
    aws s3 cp $probe "s3://$bucket/$key" --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
      $script:Skip++
      Write-Host "  [SKIP] S3 업로드 실패 (버킷 $bucket)" -ForegroundColor Yellow
    } else {
      $imgUrl = "$EP$IMAGES_PREFIX/$key"
      Test-Code "GET $IMAGES_PREFIX/$key" '2xx' @($imgUrl)
      # 본문까지 확인: OAC/rewrite 가 잘못되면 200 인데 엉뚱한 내용이 올 수 있다.
      $got = ''
      try { $got = (& curl.exe -s --max-time 10 $imgUrl 2>$null) } catch {}
      if ("$got".Trim() -eq $marker) {
        $script:Pass++
        Write-Host ("  [OK]   {0,-46} 본문 일치" -f 'body match') -ForegroundColor Green
      } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0,-46} 본문 불일치" -f 'body match') -ForegroundColor Red
        Write-Host "         받은 값: $($got.Substring(0, [Math]::Min(60, $got.Length)))" -ForegroundColor DarkGray
      }
      aws s3 rm "s3://$bucket/$key" --only-show-errors 2>$null | Out-Null
    }
  }
}

# ---------- E. CloudFront 우회 (정보성) ----------
Write-Host ""
Write-Host "E. ALB 직접 호출 차단 (403 — 정보성)" -ForegroundColor White
$albDns = ''
$tfdir = Join-Path $Here '..\terraform'
if (Test-Path $tfdir) {
  Push-Location $tfdir
  try { $albDns = (terraform output -raw alb_dns 2>$null) } catch {}
  Pop-Location
}
if ($albDns) {
  Test-Code 'GET ALB 직접' '403' @("http://$albDns$validPath")
} else {
  $script:Skip++
  Write-Host '  [SKIP] alb_dns 조회 실패' -ForegroundColor Yellow
}

# ---------- 요약 ----------
Write-Host ""
Write-Host ("=== PASS {0} / FAIL {1} / SKIP {2} ===" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor Cyan
if ($script:Fail -gt 0) {
  Write-Host ""
  Write-Host "FAIL 해석:" -ForegroundColor Yellow
  Write-Host "  A 실패 → 앱/DB 문제. 가용성 12점이 같이 죽으니 최우선. kubectl -n app get pods"
  Write-Host "  B 실패 → WAF 룰이 안 걸림. variables.tf 의 waf_blocked_* 확인 후 apply"
  Write-Host "  C 가 403 → 커스텀 룰 scope 가 너무 넓다. locals.tf 의 waf_block_scope_regex 확인"
  Write-Host "  D 실패 → S3 OAC / CloudFront images 동작 / strip_images_prefix 함수 확인"
  exit 1
}
exit 0
