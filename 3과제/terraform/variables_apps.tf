# ---------------------------------------------------------------------------
# 앱 정의 변수 — 대회날 "앱이 바뀔 때" 손대는 유일한 곳
#
# 사용법 3가지:
#  (A) 아무것도 안 건드림
#      application/binary/ 의 바이너리가 자동 발견되고 app_defaults 로 배포된다.
#      새 앱 추가/이름 변경도 바이너리만 넣으면 끝.
#
#  (B) 앱별 특성만 지정 (권장)
#      apps = {
#        user    = { cpu_request_m = 120, hpa_target_cpu = 60 }
#        product = { needs_s3 = true, cache_ttl = 10, cache_query_keys = ["id"] }
#        stress  = { isolate = true, cpu_limit_pct = 90, hpa_target_cpu = 70 }
#      }
#
#  (C) 앱 목록까지 완전 고정 (자동 발견 무시)
#      apps 에 키를 하나라도 쓰면 그 키 집합이 앱 목록이 된다.
# ---------------------------------------------------------------------------

# type = any 인 이유: 앱마다 지정하는 필드가 달라도 되게 하려면 각 값의 형태가
# 서로 달라야 한다. map(object(...)) 는 모든 원소의 타입을 하나로 통일하려 해서
# "어떤 앱만 cache_ttl 지정" 같은 부분 지정이 불가능해진다.
# 지원 키는 아래 app_defaults 와 apps.tf 주석 참조.
variable "apps" {
  type        = any
  default     = {}
  description = <<-DESC
    앱별 설정 override. 비우면 application/binary/ 자동 발견 + app_defaults 적용.
    지원 키:
      path, node_port, container_port, healthcheck_path
      cpu_request_m | cpu_request_pct   (pct = 노드 앱가용 CPU 의 %)
      cpu_limit_m   | cpu_limit_pct
      memory_request, memory_limit
      min_replicas, max_replicas, hpa_target_cpu
      needs_db, needs_s3, isolate
      cache_ttl, cache_query_keys
      env (map(string))
  DESC

  validation {
    condition     = can(keys(var.apps))
    error_message = "apps must be a map keyed by app name."
  }
}

# 모든 앱의 공통 기본값. 앱이 바뀌어도 대체로 이 값으로 뜬다.
variable "app_defaults" {
  type = object({
    cpu_request_m = optional(number, 200)
    cpu_limit_m   = optional(number, null)

    # CPU limit = request x 이 비율. 0 이면 limit 을 걸지 않는다(기본).
    #
    # ⚠ 기본을 0(무제한)으로 두는 이유 — 실측으로 크게 실패했다:
    #   limit 을 걸면 CFS 가 100ms 주기마다 쿼터를 끊는다. 지연 민감 앱은 쿼터를 다 쓴
    #   순간부터 다음 주기까지 강제로 멈추므로 꼬리지연이 폭증한다.
    #   실측: product 를 request 50m / limit 75m 로 묶었더니 가용성이 100% -> 65.1%,
    #   성능이 84.3% -> 51.3% 로 무너졌다(타임아웃). 이웃 CPU 보호보다 손해가 훨씬 컸다.
    #
    # 이웃을 굶기는 문제는 limit 이 아니라 (a) request 를 실사용에 맞추기
    # (b) 서로 다른 앱을 다른 노드로 분산(pod anti-affinity) 로 푼다.
    # 꼭 상한이 필요하면 1.5~2 정도를 주되, 지연 민감 앱에는 걸지 않는다.
    cpu_limit_ratio  = optional(number, 0)
    memory_request   = optional(string, "128Mi")
    memory_limit     = optional(string, "256Mi")
    min_replicas     = optional(number, 4)
    max_replicas     = optional(number, 12)
    hpa_target_cpu   = optional(number, 50)
    needs_db         = optional(bool, true)
    needs_s3         = optional(bool, false)
    isolate          = optional(bool, false)
    isolate_hard     = optional(bool, false)
    cache_ttl        = optional(number, 0)
    cache_query_keys = optional(list(string), [])
  })
  default = {}

  description = <<-DESC
    앱 공통 기본값 = '튜닝 전 시작값'. 실제 값은 튜너가 실측해 app_tuning 에 덮어쓴다.

    성능 우선으로 넉넉하게 잡는다. 시작값이 너무 낮으면 첫 부하 구간에서 파드가
    부족해 초반 요청을 놓치고, 그 손실은 뒤에서 회복되지 않는다(누적 % 채점).
    CPU limit 은 걸지 않는다(cpu_limit_ratio=0) — CFS 스로틀링이 꼬리지연을 만든다.
  DESC
}

# ---------------------------------------------------------------------------
# 튜닝 툴이 기계적으로 쓰는 값 (tuning/ 이 tuning.auto.tfvars 로 생성)
#
# 왜 var.apps 와 분리하는가:
#   var.apps 는 사람이 쓰는 '구조' 설정이다(needs_s3, isolate, cache_ttl, 경로...).
#   튜너가 var.apps 를 덮어쓰면 맵 전체가 교체되어 그런 구조 설정이 조용히 사라진다.
#   그래서 튜너는 이 변수만 건드리고, apps.tf 가 var.apps 위에 병합한다.
#   → 사람 설정과 기계 설정이 절대 충돌하지 않고, 둘 다 Terraform 이 소유한다.
#
# 우선순위: app_tuning > apps > app_defaults
#
# 이 파일(tuning.auto.tfvars)은 자동 생성물이므로 손으로 고치지 않는다.
# 튜닝을 버리려면 파일을 지우고 terraform apply 하면 apps 값으로 되돌아간다.
# ---------------------------------------------------------------------------
variable "app_tuning" {
  type        = any
  default     = {}
  description = <<-DESC
    튜닝 툴이 생성하는 앱별 수치 override. 지원 키:
      cpu_request_m, hpa_target_cpu, min_replicas, max_replicas
    tuning/optimize.ps1 이 tuning.auto.tfvars 에 기록한다. 수동 편집 금지.
  DESC

  validation {
    condition     = can(keys(var.app_tuning))
    error_message = "app_tuning must be a map keyed by app name."
  }
}

# application/binary/ 에서 앱으로 취급하지 않을 파일 이름
variable "app_binary_exclude" {
  type        = list(string)
  default     = ["Dockerfile", ".gitignore", "README.md"]
  description = "앱 바이너리 자동 발견에서 제외할 파일명."
}

# ---------------------------------------------------------------------------
# DB 초기화 — 대회날 스키마가 바뀌면 여기만 고친다 (k8s_base.tf 수정 불필요)
# ---------------------------------------------------------------------------

variable "db_schema_sql" {
  type        = string
  description = <<-DESC
    db-init Job 이 실행할 스키마 SQL. 대회날 테이블 구조가 바뀌면 이 값만 교체.
    멱등해야 한다 (CREATE TABLE IF NOT EXISTS 등) — Job 이 재시도될 수 있다.
    조회 조건으로 쓰이는 컬럼에는 반드시 인덱스를 걸어야 한다: 인덱스가 없으면
    풀스캔이 되어 응답시간 SLO(0.2s)를 절대 만족할 수 없다. 문제지도 트래픽
    패턴에 맞춘 테이블 재설계를 허용한다.
  DESC

  default = <<-SQL
    CREATE TABLE IF NOT EXISTS user (
      id VARCHAR(255) NOT NULL,
      username VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL,
      PRIMARY KEY (id),
      UNIQUE KEY uk_username (username),
      KEY idx_email (email)
    );
    CREATE TABLE IF NOT EXISTS product (
      id VARCHAR(255) NOT NULL,
      name VARCHAR(255) NOT NULL,
      price FLOAT(8) NOT NULL,
      image_path VARCHAR(500) DEFAULT NULL,
      PRIMARY KEY (id)
    );
  SQL
}

# 이미 존재하는 테이블에 인덱스를 덧붙일 때 사용 (테이블이 먼저 만들어진 경우 대비).
# information_schema 를 확인하고 없을 때만 ALTER 하므로 멱등하다.
variable "db_required_indexes" {
  type = list(object({
    table  = string
    index  = string
    column = string
  }))
  default = [
    { table = "user", index = "idx_email", column = "email" },
  ]
  description = "조회 조건 컬럼 인덱스 보장 목록. 없으면 ALTER TABLE 로 추가한다(멱등)."
}

# 시드 덤프를 적재할 테이블 (비어 있을 때만 적재해 멱등성 유지)
variable "db_seed_table" {
  type        = string
  default     = "user"
  description = "load_user.dump 적재 대상 테이블. 이 테이블이 비어 있을 때만 적재한다."
}
