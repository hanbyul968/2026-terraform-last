# ===== 대회날 여기만 수정 (PowerShell 판) =====
# 부하/채점 대상 정의. loadtest.ps1 / autotune.ps1 / autotune-hc.ps1 이 이 파일을 dot-source 한다:
#     . .\config.ps1

# 엔드포인트 — 대회날 여기 한 번만 붙여넣으면 loadtest/autotune/autotune-hc 전부 이 값을 쓴다.
# (스크립트에 -Url 로 넘기면 그 값이 우선)

if (-not $ENDPOINT) { $ENDPOINT = 'http://REPLACE-ME.cloudfront.net' }

# 공통 식별자(앱이 요구하면). 안 쓰면 비워둬도 됨.
if (-not $UUID) { $UUID = '7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729' }

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
# 쿠버네티스 네임스페이스.
if (-not $NS) { $NS = 'app' }

# SLO 문자열("user=0.2,product=0.2,...") — score.py 로 넘길 때 사용.
$SLOS = ($APIS | ForEach-Object { "$($_.name)=$($_.slo)" }) -join ','
