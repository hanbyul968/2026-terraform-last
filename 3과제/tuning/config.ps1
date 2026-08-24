# ===== 대회날 여기만 수정 (PowerShell 판) =====
# 부하/채점 대상 정의. loadtest.ps1 / autotune.ps1 / autotune-hc.ps1 이 이 파일을 dot-source 한다:
#     . .\config.ps1

# ---------------------------------------------------------------------------
# 콘솔 출력 인코딩을 UTF-8 로 맞춘다.
# 스크립트는 한글을 UTF-8 로 출력하는데, PowerShell 콘솔 코드페이지가 949(한글 완성형)이면
# 글자가 깨져 보인다("기록" -> "湲곕줉"). 표시만의 문제지만 읽기 나쁘므로 세션 인코딩을 맞춘다.
# 파일 쓰기(tuning.auto.tfvars.json)는 이미 BOM 없는 UTF-8 로 별도 처리하므로 영향 없다.
try {
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
  $OutputEncoding = [Text.UTF8Encoding]::new()
  $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
} catch {}

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
# 측정 전 시딩. 부하가 실제로 존재하는 행을 조회해야 200 이 나온다.
#
# load_user.dump 가 이미 user/product 각 10만 행(dbdump500001~600000)을 넣으므로
# 그 범위를 조회하는 한 시딩은 필요 없다. 여기서 임의 행을 더 넣으면 안 된다 —
# 문제지: "발생하는 트래픽 외 임의의 데이터를 삽입하면 성능 저하가 생길 수 있으므로 주의".
#
# 비워 두는 것이 기본이다. 대회날 덤프가 없거나 스키마가 바뀌어 조회가 404 라면,
# 그때만 아래에 POST 를 추가하고 $KEY_* 를 그 키에 맞춘다.
$SEEDS = @()

# 부하 대상 API 목록.
#   name    : 결과 라벨 + (autotune 에서) 같은 이름의 Deployment 를 튜닝
#   slo     : 채점기준의 성능 SLO(초). 이 시간 이내 = perf OK
#   conc/qps: hey -c / -q
#   method  : GET | POST
#   path    : 쿼리 포함 경로
#   body    : POST 일 때 JSON, GET 이면 $null
# 요청 키를 '분산'시켜야 한다. 고정 키 하나로 때리면 측정이 채점과 완전히 달라진다.
#
#   실측 사고 — product 를 고정 id(loadseedp1) 로만 때렸더니 CloudFront 가 그 하나를
#   캐싱해 우리 측정은 항상 99.7% 였다. 그런데 채점 트래픽은 여러 id 를 쓰므로 캐시 미스가
#   나고 오리진·DB 까지 가서 실제 점수는 77.2% 였다. user 도 고정 이메일이라 같은 문제였고,
#   그 낙관적 측정 위에서 뽑은 튜닝값이 실제 트래픽에서 안 들어 user 29.5%(게이트 발동,
#   비용 12점 전부 상실)로 이어졌다.
#
# load_user.dump 의 실제 키 공간은 dbdump500001 ~ dbdump600000 (user/product 각 10만개)다.
# 그 범위에서 골라야 GET 이 200 을 받는다(없는 키면 404 라 측정이 무의미해진다).
# $KEY_SPREAD 개의 키로 부하를 쪼개므로, 캐시 히트율과 DB 접근 비율이 채점과 비슷해진다.
# 대회날 앱/스키마가 바뀌면 $KEY_PREFIX·$KEY_MIN·$KEY_MAX 만 새 덤프에 맞춰 고친다.
if (-not $KEY_PREFIX)  { $KEY_PREFIX = 'dbdump' }
if (-not $KEY_MIN)     { $KEY_MIN = 500001 }
if (-not $KEY_MAX)     { $KEY_MAX = 600000 }
if (-not $KEY_SPREAD)  { $KEY_SPREAD = 20 }   # 부하를 나눌 키 개수 (1 이면 옛 동작=고정키)

# 키 목록을 균등 간격으로 뽑는다(무작위보다 재현성이 좋아 회차 비교가 가능하다).
$KEYS = @()
if ($KEY_SPREAD -le 1) {
  $KEYS = @("$KEY_PREFIX$KEY_MIN")
} else {
  $step = [math]::Floor(($KEY_MAX - $KEY_MIN) / $KEY_SPREAD)
  for ($i = 0; $i -lt $KEY_SPREAD; $i++) { $KEYS += "$KEY_PREFIX$($KEY_MIN + $i * $step)" }
}

# keys 가 있는 API 는 loadtest.ps1 이 키마다 부하를 쪼개 실행한다.
# pathFmt 의 {KEY} 자리에 키가 들어간다.
$APIS = @(
  @{ name = 'user';    slo = 0.2; conc = 30; qps = 10; method = 'GET';  keys = $KEYS; pathFmt = "/v1/user?email={KEY}@example.org&requestid=1&uuid=$UUID"; body = $null }
  @{ name = 'product'; slo = 0.2; conc = 30; qps = 10; method = 'GET';  keys = $KEYS; pathFmt = "/v1/product?id={KEY}&requestid=1&uuid=$UUID";            body = $null }
  @{ name = 'stress';  slo = 1.0; conc = 12; qps = 2;  method = 'POST'; path = '/v1/stress'; body = (@{ requestid = '1'; uuid = $UUID; length = 64 } | ConvertTo-Json -Compress) }
)

# 가용성 합격선(%) — 이 밑이면 autotune 점수에서 실격 처리.
if (-not $AVAIL_GATE)   { $AVAIL_GATE = 99 }
# 노드 1대(평균) 초과당 비용 패널티 점수.
if (-not $COST_PENALTY) { $COST_PENALTY = 6 }
# 비용 ratio 분모의 점 추정값. 단위는 '노드 대수'가 아니라 **기준 인스턴스 대수**다
# (TUNE_NODE_REFERENCE, 기본 t3.medium). 인스턴스 타입을 키우면 엔진이 노드 수에
# 상대 비용을 곱해 이 단위로 환산하므로, 타입을 바꿔도 이 값은 그대로 둔다.
#
# 실제 분모는 비공개다. score.py / advise.py 는 이 점 추정값 하나로 보고하지만,
# optimize.ps1 의 프론티어는 -CostBaselines 그리드(기본 2,3,4) 전체에서 평가해
# 어떤 분모여도 손해가 가장 작은 운영점을 고른다. 즉 이 값이 조금 틀려도
# 튜닝 결정 자체는 흔들리지 않는다 — 리포트 숫자만 그 가정 위에서 읽힌다.
if (-not $COST_BASELINE_NODES) { $COST_BASELINE_NODES = 2 }
# 쿠버네티스 네임스페이스.
if (-not $NS) { $NS = 'app' }

# ---------------------------------------------------------------------------
# Terraform 디렉터리 — 튜닝 결과를 반영하는 곳.
#
# 튜닝 툴은 클러스터를 kubectl 로 직접 고치지 않는다. tuning.auto.tfvars.json 에
# 목표값을 쓰고 terraform apply 로 반영한다. 그래야 라이브 상태와 Terraform state 가
# 항상 일치하고(드리프트 없음), 누가 terraform apply 를 해도 튜닝이 날아가지 않는다.
# WSI_TF_DIR 환경변수로 덮어쓸 수 있다.
# ---------------------------------------------------------------------------
if (-not $TF_DIR) {
  $TF_DIR = if ($env:WSI_TF_DIR) { $env:WSI_TF_DIR }
            else { Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform' }
}
if (-not (Test-Path $TF_DIR)) { throw "terraform 디렉터리를 찾을 수 없습니다: $TF_DIR (WSI_TF_DIR 로 지정하세요)" }

# score.py / advise.py 가 읽는다 (인자 순서를 건드리지 않기 위해 환경변수로 전달).
$env:TUNE_BASELINE_NODES = "$COST_BASELINE_NODES"

# SLO 문자열("user=0.2,product=0.2,...") — score.py 로 넘길 때 사용.
$SLOS = ($APIS | ForEach-Object { "$($_.name)=$($_.slo)" }) -join ','
