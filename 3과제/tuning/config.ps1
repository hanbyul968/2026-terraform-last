# ===== 대회날 여기만 수정 (PowerShell 판) =====
# 부하/채점 대상 정의. loadtest.ps1 / autotune.ps1 / autotune-hc.ps1 이 이 파일을 dot-source 한다:
#     . .\config.ps1

# 엔드포인트 해석 — 우선순위: $env:ENDPOINT > `terraform output endpoint`.
# ⚠ 매 실행마다 새로 계산한다(세션에 옛 주소가 캐시돼 죽은 도메인을 계속 쓰던 버그 방지).
#   - 다른 주소 강제: 스크립트에 -Url http://... (최우선), 또는  $env:ENDPOINT = 'http://...'
#   - 하드코딩 금지: 못 읽으면 빈값 → loadtest.ps1 이 "-Url 로 전달" 에러를 낸다(죽은 주소로 조용히 안 감).
#   - -chdir= 는 PowerShell 5.1 에서 파싱이 깨질 수 있어 Push-Location 으로 디렉터리를 옮겨 실행.
if ($env:ENDPOINT) {
  $ENDPOINT = $env:ENDPOINT
} else {
  $ENDPOINT = ''
  $tfdir = Join-Path $PSScriptRoot '..\terraform'
  if (Test-Path $tfdir) {
    Push-Location $tfdir
    try { $ENDPOINT = (terraform output -raw endpoint 2>$null) } catch {}
    Pop-Location
  }
}
if ($ENDPOINT) { $ENDPOINT = "$ENDPOINT".Trim() }

# 공통 식별자(앱이 요구하면). 안 쓰면 비워둬도 됨.
if (-not $UUID) { $UUID = '7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729' }

# 헬스체크 경로 (verify.ps1 이 사용). terraform var.healthcheck_path 와 맞춘다.
if (-not $HC_PATH) { $HC_PATH = '/healthcheck' }

# 이미지 다운로드 경로 prefix (verify.ps1 이 사용). terraform var.images_prefix 와 맞춘다.
if (-not $IMAGES_PREFIX) { $IMAGES_PREFIX = '/images' }

# 측정 전에 한 번 넣어둘 시드 레코드 (GET 부하가 실제 행을 맞히게).
#   method: GET|POST,  path,  body(JSON; GET 이면 $null)
$SEEDS = @(
  @{ method = 'POST'; path = '/v1/user';    body = (@{ requestid = '1'; uuid = $UUID; username = 'loadseed1'; email = 'loadseed1@example.org' } | ConvertTo-Json -Compress) }
  @{ method = 'POST'; path = '/v1/product'; body = (@{ requestid = '1'; uuid = $UUID; id = 'loadseedp1'; name = 'loadseedp1'; price = 1 } | ConvertTo-Json -Compress) }
)

# 부하 대상 API 목록.
#   name    : 결과 라벨 + (autotune 에서) 같은 이름의 Deployment 를 튜닝
#   slo     : 채점기준의 성능 SLO(초). 이 시간 이내 = perf OK
#   conc/qps: hey -c / -q
#   method  : GET | POST
#   path    : 쿼리 포함 경로
#   body    : POST 일 때 JSON, GET 이면 $null
$APIS = @(
  @{ name = 'user';    slo = 0.2; conc = 30; qps = 10; method = 'GET';  path = "/v1/user?email=loadseed1@example.org&requestid=1&uuid=$UUID"; body = $null }
  @{ name = 'product'; slo = 0.2; conc = 30; qps = 10; method = 'GET';  path = "/v1/product?id=loadseedp1&requestid=1&uuid=$UUID";           body = $null }
  @{ name = 'stress';  slo = 1.0; conc = 12; qps = 2;  method = 'POST'; path = '/v1/stress'; body = (@{ requestid = '1'; uuid = $UUID; length = 64 } | ConvertTo-Json -Compress) }
)

# 가용성 합격선(%) — 이 밑이면 autotune 점수에서 실격 처리.
if (-not $AVAIL_GATE)   { $AVAIL_GATE = 99 }
# 노드 1대(평균) 초과당 비용 패널티 점수.
if (-not $COST_PENALTY) { $COST_PENALTY = 6 }
# 비용 패널티 기준선(노드 수). 이 대수까지는 패널티 0, 초과분에만 부과한다.
# terraform 의 node_desired_size 와 맞춘다 (현재 1). 안 맞으면 autotune 이
# 엉뚱한 조합을 우승으로 뽑는다.
if (-not $COST_BASELINE_NODES) { $COST_BASELINE_NODES = 1 }
# 쿠버네티스 네임스페이스.
if (-not $NS) { $NS = 'app' }

# score.py / advise.py 가 읽는다 (인자 순서를 건드리지 않기 위해 환경변수로 전달).
$env:TUNE_BASELINE_NODES = "$COST_BASELINE_NODES"

# SLO 문자열("user=0.2,product=0.2,...") — score.py 로 넘길 때 사용.
$SLOS = ($APIS | ForEach-Object { "$($_.name)=$($_.slo)" }) -join ','
