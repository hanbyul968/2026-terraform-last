# ===========================================================================
# 앱 설정 — 대회날 앱이 바뀌면 이 블록만 고친다 (terraform 코드 수정 불필요)
#
# 앱 목록 자체는 application/binary/ 에서 자동 발견되므로, 여기 키를 쓰지 않은 앱도
# app_defaults 로 정상 배포된다. 아래는 "앱별 특성"만 지정한 것이다.
#
# ── 핵심 원칙 1: cpu_request 는 실측 사용량에 맞춘다 ──
#   request 를 과대 설정하면 두 가지가 동시에 망가진다.
#   (a) HPA 실명: 사용률 = 실사용/request. request 425m 에 실사용 40m 이면 9% 로 보여
#       목표 90% 에 영원히 못 닿아 확장이 안 된다(실측된 실패 모드).
#   (b) 비용 상승: 스케줄러는 request 로 bin-packing 하므로 한가한 노드가 계속 늘어난다.
#   여유는 request 가 아니라 hpa_target_cpu 로 확보한다.
#
# ── 핵심 원칙 2: CPU 폭식 앱은 isolate 한다 ──
#   실측: 트래픽 4% 인 stress 가 클러스터 CPU 를 거의 다 먹어, 트래픽 75% 인 user 의
#   p50 이 27ms -> 330ms 로 악화되어 0.2s SLO 를 놓쳤다(성능 24.2%).
#   채점표상 비용 12점은 "모든 앱 성능 >= 30%" 게이트를 통과해야 받으므로,
#   user 가 24.2% 인 순간 비용 12점이 통째로 0 이 됐다. 격리가 그 게이트를 살린다.
# ===========================================================================
apps = {
  # 조회/생성 API. DB I/O 바운드라 CPU 를 거의 쓰지 않는다 → request 를 낮게 잡아야
  # HPA 가 부하를 감지할 수 있다. 지연 민감(0.2s) → 절대 격리 노드로 보내지 않는다.
  user = {
    cpu_request_m  = 120
    hpa_target_cpu = 55
    min_replicas   = 3
    max_replicas   = 10
  }

  # 같은 id 로 반복 조회된다(문제지 명시) → CloudFront 캐시가 오리진 부하와 지연을
  # 동시에 줄인다. 이미지 업로드 때문에 S3 쓰기 권한(IRSA) 필요.
  product = {
    cpu_request_m    = 100
    hpa_target_cpu   = 55
    min_replicas     = 3
    max_replicas     = 10
    needs_s3         = true
    cache_ttl        = 10
    cache_query_keys = ["id"]
  }

  # CPU 를 많이 쓰는 앱. 별도 노드로 격리하지 않는다(isolate 미사용).
  #
  # 격리를 안 써도 되는 이유: 모든 앱이 limit = request (app_defaults.cpu_limit_ratio=1)
  # 라서 어떤 파드도 예약분을 넘겨 이웃 CPU 를 빼앗지 못한다. 노드를 나누지 않아도
  # 지연 민감 앱이 보호되고, 전용 노드가 없으니 유휴 시 Karpenter 노드가 0대가 된다.
  # 부하는 HPA 가 파드 수로 흡수한다.
  #
  # ⚠ request 값이 이 앱의 처리량 상한을 결정한다(limit = request 이므로).
  #   500m 은 확정값이 아니다 — 요청당 CPU 비용을 신뢰할 만큼 측정하지 못했다.
  #   부하 결과에서 이 앱의 성능%가 낮으면 request 를 올리고(파드당 처리량↑),
  #   그래도 부족하면 max_replicas 를 올린다.
  stress = {
    needs_db       = false
    cpu_request_m  = 500
    hpa_target_cpu = 65
    min_replicas   = 2
    max_replicas   = 8
  }
}

# Karpenter 상한은 지정하지 않는다 — 앱 맵에서 자동 계산된다(sizing.tf).
# 앱이 추가/삭제되거나 max_replicas 가 바뀌면 상한도 따라 움직인다.
# 굳이 고정하려면 karpenter_max_nodes 또는 karpenter_cpu_limit 을 준다.

# 격리 노드풀(stress) 상한.
#
# ⚠ 비용 ratio 의 분모(기준 인스턴스 대수/비용)는 문제지·채점기준표 어디에도 공개되지
#   않는다. 따라서 "노드 N대 = 비용 M점" 같은 환산은 추정일 뿐이며 여기 적지 않는다.
#   확실한 것 두 가지만 근거로 삼는다:
#     (1) 채점표 4-1~4-12 는 모두 "모든 앱 성능 >= 30%" 를 함께 요구한다 → 게이트는 실재한다.
#     (2) ratio 는 노드 수에 비례하므로 노드가 적을수록 유리하다(방향만 확실).
#   그래서 stress 를 30% 위로 유지하는 선에서 노드를 낮게 잡고, 정확한 값은 실측으로 찾는다.
karpenter_isolated_max_nodes = 3

# ===========================================================================
# WAF 커스텀 차단 (waf.tf 수정 없이 변수로만 제어)
# ===========================================================================
# x-api-version: 로그 실측상 이 헤더를 쓰는 요청은 100% 공격(Shellshock/JNDI),
# 정상 트래픽은 이 헤더를 전혀 안 씀 → 존재만으로 403 (오탐 0).
waf_blocked_headers = ["x-junk", "x-api-version", "X-Forwarded-Host", "X-Forwarded-For"]

# python-urllib: 정상 채점 트래픽은 Go-http-client/1.1 만 사용 → python-urllib 는 정찰/스캐너.
# 리스트 변수는 덮어쓰기이므로 기본값 전체 + 새 토큰을 함께 나열해야 함.
waf_blocked_user_agents = [
  "sqlmap",
  "nikto",
  "nmap",
  "masscan",
  "acunetix",
  "havij",
  "nuclei",
  "wpscan",
  "dirbuster",
  "gobuster",
  "attack",
  "bin/bash",
  "ZAP",
  "/bin/bash"
]

# multipart/form-data 차단 (사용자 요청). Content-Type 헤더 값에 포함되면 403.
waf_blocked_header_values = [
]

waf_blocked_query_patterns = [
  "/etc/passwd",
  "hijack",
  "$gt",
  "$where",
  "passwd",
]