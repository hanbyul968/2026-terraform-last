# ---------------------------------------------------------------------------
# 앱 정의 단일 소스 (Single Source of Truth)
#
# 대회날 앱이 바뀌면 여기만 본다:
#   1) application/binary/ 에 새 바이너리를 넣으면 자동으로 발견된다
#      (ECR repo / 이미지 빌드+푸시 / Deployment / Service / HPA / PDB /
#       ALB TargetGroup + 리스너 룰 / WAF scope / CloudFront 동작 전부 자동 생성)
#   2) 앱별 특성(경로, DB 사용, S3 사용, 캐시, 격리, 사이징)만 var.apps 로 덮어쓴다
#
# 즉 "앱 추가/삭제/이름변경" 은 terraform 코드 수정이 아니라 tfvars 수정 작업이 된다.
# ---------------------------------------------------------------------------

locals {
  # ---------- 1. 바이너리 자동 발견 ----------
  # application/binary/ 안의 Dockerfile 을 제외한 모든 파일 = 앱 하나.
  # 대회날 바이너리 이름이 order/payment 로 바뀌어도 코드 수정 없이 잡힌다.
  binary_dir = "${path.module}/../application/binary"

  discovered_apps = sort([
    for f in fileset(local.binary_dir, "*") : f
    if !contains(var.app_binary_exclude, f)
  ])

  # 앱 목록은 '바이너리' 가 정한다. var.apps 는 override 용일 뿐이다.
  #
  # var.apps 의 키를 앱 목록으로 쓰면 안 되는 이유: tfvars 에 일부 앱만 적어두면
  # (예: 구조 설정이 필요한 product/stress 만) 나머지 앱이 통째로 사라진다.
  # 실측: user 를 tfvars 에서 빼자 Deployment/Service/HPA 가 전부 없어졌다.
  # 바이너리가 진실이므로 그것을 목록으로 삼고, tfvars 는 값만 얹는다.
  # (바이너리를 못 찾은 경우에만 var.apps 키로 대체 — 예: 이미지 태그를 직접 주는 경우)
  app_names = length(local.discovered_apps) > 0 ? local.discovered_apps : sort(keys(var.apps))

  # ---------- 2. 앱별 설정 = 기본값 + 개별 override ----------
  d = var.app_defaults

  # ---------- request/limit 사전 계산 ----------
  # apps 맵을 만들면서 자기 자신을 참조할 수 없으므로 먼저 따로 계산한다.
  request_m_for = {
    for name in local.app_names : name => (
      try(var.app_tuning[name].cpu_request_m, null) != null ? var.app_tuning[name].cpu_request_m : (
        try(var.apps[name].cpu_request_pct, null) != null ? (
          max(ceil(local.node_app_cpu_m * var.apps[name].cpu_request_pct / 100), 10)
        ) : try(var.apps[name].cpu_request_m, local.d.cpu_request_m)
      )
    )
  }

  cpu_limit_ratio_for = {
    for name in local.app_names : name =>
    try(var.apps[name].cpu_limit_ratio, local.d.cpu_limit_ratio)
  }

  apps = {
    for idx, name in local.app_names : name => {
      # --- 라우팅 ---
      # 경로: 명시값 > api_paths_override > "<api_prefix>/<앱이름>"
      path = try(var.apps[name].path, null) != null ? var.apps[name].path : "${var.api_prefix}/${name}"

      # NodePort: 기본은 지정하지 않고 쿠버네티스가 자동 배정한다(null).
      #
      # 하드코딩하면 안 되는 이유: ALB 는 target_type=ip + TargetGroupBinding 으로
      # '파드 IP' 에 직접 등록하므로 nodePort 는 라우팅에 쓰이지 않는다. 그런데 앱이
      # 추가/삭제/이름변경되면 정렬 순서가 바뀌어 포트가 재배정되고, 기존 Service 와
      # 충돌해 apply 가 깨진다("provided port is already allocated").
      # 꼭 고정이 필요하면 var.apps 에서 node_port 를 명시한다.
      node_port = try(var.apps[name].node_port, null)

      # ALB TargetGroup name_prefix 는 최대 6자 → 앱 이름 앞 5자 + "-"
      tg_prefix = "${substr(name, 0, 5)}-"

      # --- 사이징 (인스턴스 타입에서 파생 가능) ---
      # cpu_request_pct 를 주면 노드 앱 가용 CPU 의 비율로 계산 → 타입이 바뀌면 자동 조정.
      # 둘 다 없으면 app_defaults.cpu_request_m.
      #
      # ⚠ request 는 "실측 사용량"에 맞춰야 한다. 과대 설정하면 두 가지가 동시에 망가진다:
      #   (a) HPA 가 눈이 먼다 — 사용률 = 실사용/request 이므로 request 가 10배면
      #       사용률이 10분의 1로 보여 목표치에 영원히 도달하지 못해 스케일아웃이 안 된다.
      #       (실측: user 파드가 request 425m 에 실사용 40m → 9%/90% 로 확장 불가)
      #   (b) 비용이 오른다 — 스케줄러는 request 로 bin-packing 하므로 과대 request 는
      #       실제로 한가한 노드를 계속 추가하게 만든다(비용 ratio = 평균 노드 수).
      cpu_request_m = local.request_m_for[name]

      # CPU limit. 기본은 request 와 같게 둔다(cpu_limit_ratio=1).
      #
      # 왜 limit = request 인가 (앱이 무엇이든 성립하는 규칙):
      #   파드가 request 보다 크게 burst 할 수 있으면 그만큼을 같은 노드의 이웃에게서
      #   빼앗는다. cgroup CPU 는 share 비율로 나뉘므로, burst 하는 파드가 항상 이긴다.
      #   실측: request 500m / limit 1503m 인 앱이 실제로 3배까지 먹어, CPU 를 거의 안 쓰는
      #   지연 민감 앱(request 의 9%만 사용)의 p50 이 27ms -> 330ms 로 무너졌다.
      #   limit = request 면 어떤 파드도 예약분을 넘지 못하므로 이웃이 굶지 않는다.
      #   부하가 늘면 '한 파드가 더 먹는' 대신 HPA 가 파드 수를 늘려 처리한다(정상 경로).
      #
      # 이 규칙은 앱 이름/성격을 몰라도 적용된다 — 대회날 앱이 바뀌어도 그대로 유효하다.
      # burst 를 허용하려면 cpu_limit_ratio 를 1 보다 크게(예: 1.5) 주거나
      # cpu_limit_m / cpu_limit_pct 로 직접 지정한다.
      cpu_limit_m = try(var.apps[name].cpu_limit_pct, null) != null ? (
        max(ceil(local.node_app_cpu_m * var.apps[name].cpu_limit_pct / 100), 10)
        ) : try(var.apps[name].cpu_limit_m, null) != null ? var.apps[name].cpu_limit_m : (
        local.cpu_limit_ratio_for[name] > 0 ?
        ceil(local.request_m_for[name] * local.cpu_limit_ratio_for[name]) : null
      )

      memory_request = try(var.apps[name].memory_request, local.d.memory_request)
      memory_limit   = try(var.apps[name].memory_limit, local.d.memory_limit)

      # --- 오토스케일 (튜닝 툴이 app_tuning 으로 덮어쓸 수 있는 값) ---
      min_replicas   = try(var.app_tuning[name].min_replicas, null) != null ? var.app_tuning[name].min_replicas : try(var.apps[name].min_replicas, local.d.min_replicas)
      max_replicas   = try(var.app_tuning[name].max_replicas, null) != null ? var.app_tuning[name].max_replicas : try(var.apps[name].max_replicas, local.d.max_replicas)
      hpa_target_cpu = try(var.app_tuning[name].hpa_target_cpu, null) != null ? var.app_tuning[name].hpa_target_cpu : try(var.apps[name].hpa_target_cpu, local.d.hpa_target_cpu)

      # --- 앱 동작 ---
      needs_db = try(var.apps[name].needs_db, local.d.needs_db)
      needs_s3 = try(var.apps[name].needs_s3, local.d.needs_s3)

      # isolate=true → 전용(taint 걸린) 노드풀로 격리한다.
      # CPU 를 폭식하는 앱(예: stress 류)을 지연에 민감한 앱과 같은 노드에 두면
      # 폭식 앱이 CPU 를 다 먹고 민감한 앱의 응답이 SLO 를 넘긴다.
      # (실측: 트래픽의 4% 인 stress 가 클러스터 CPU 의 대부분을 소비해
      #  트래픽 75% 인 user 의 p50 이 27ms -> 330ms 로 악화, 200ms SLO 탈락)
      isolate = try(var.apps[name].isolate, local.d.isolate)

      # isolate_hard=true → 전용 노드에만 뜬다(nodeSelector 하드).
      # 유휴에도 전용 노드 1대가 남는 대가를 치르므로 기본은 false 다.
      # 기본(false)은 toleration + 선호 affinity → 유휴엔 NG, 부하엔 전용 노드.
      isolate_hard = try(var.apps[name].isolate_hard, local.d.isolate_hard)

      # CloudFront GET 캐시. 같은 응답이 반복되는 조회형 API 에 매우 효과적이다
      # (오리진 부하와 지연을 동시에 줄인다). 0 이면 캐시하지 않는다.
      cache_ttl        = try(var.apps[name].cache_ttl, local.d.cache_ttl)
      cache_query_keys = try(var.apps[name].cache_query_keys, local.d.cache_query_keys)

      # 추가 환경변수 (앱이 요구하는 키가 바뀌어도 tfvars 로 대응)
      env = try(var.apps[name].env, {})

      # 헬스체크 경로 (앱별로 다를 수 있음)
      healthcheck_path = try(var.apps[name].healthcheck_path, var.healthcheck_path)

      # 컨테이너 포트 (앱별로 다를 수 있음)
      container_port = try(var.apps[name].container_port, var.container_port)
    }
  }

  # ---------- 3. 파생 목록 (다른 파일들이 참조) ----------
  # 격리가 필요한 앱이 하나라도 있으면 전용 노드풀을 만든다.
  isolated_apps      = [for n, a in local.apps : n if a.isolate]
  need_isolated_pool = length(local.isolated_apps) > 0

  # CloudFront 에서 캐시할 앱
  cached_apps = { for n, a in local.apps : n => a if a.cache_ttl > 0 }

  # S3 쓰기 권한(IRSA)이 필요한 앱
  s3_apps = { for n, a in local.apps : n => a if a.needs_s3 }

  # DB 자격증명이 필요한 앱
  db_apps = { for n, a in local.apps : n => a if a.needs_db }

  # 이전 코드가 참조하던 이름 유지 (alb.tf / locals.tf 호환)
  node_ports = { for n, a in local.apps : n => a.node_port }

  # 앱 이름 하드코딩을 피하기 위한 대표 앱 (헬스체크 라우팅 등에 사용)
  first_app = length(local.app_names) > 0 ? sort(keys(local.apps))[0] : ""
}
