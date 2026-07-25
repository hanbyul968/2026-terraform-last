variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project" {
  type    = string
  default = "wsi2026"
}

# EKS 클러스터가 아직 없을 때(import/최초 클러스터 생성 단계) false 로 두면
# kubernetes/helm/kubectl provider 가 더미 값을 써서 "Invalid provider configuration"
# 에러 없이 진행됩니다. 클러스터가 생성된 뒤 true 로 바꿔 k8s 리소스를 apply 하세요.
variable "k8s_provider_ready" {
  type    = bool
  default = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2b"]
}

variable "eks_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "db_name" {
  type    = string
  default = "dev"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "app_image_tag" {
  type        = string
  default     = "latest"
  description = "Tag of the user/product/stress images pushed to ECR"
}

variable "aws_profile" {
  type        = string
  default     = ""
  description = "AWS named profile. Leave empty to use the default credential chain (env vars / default profile)."
}

# ---------- 경로/포트 (대회날 스펙 변경 대응: 여기 값만 바꿔 apply) ----------

variable "api_prefix" {
  type        = string
  default     = "/v1"
  description = "API 경로 prefix. 앱 경로는 <api_prefix>/<앱이름> 으로 계산됨 (예: /v1/user). 대회날 /v2 로 바뀌면 이 값만 변경."
}

variable "api_paths_override" {
  type        = list(string)
  default     = []
  description = "앱 이름과 경로가 일치하지 않을 때만 사용 (예: [\"/v2/member\",\"/v1/product\",\"/v1/stress\"]). 비어 있으면 api_prefix/<앱이름> 자동 계산."
}

variable "healthcheck_path" {
  type        = string
  default     = "/healthcheck"
  description = "앱 헬스체크 경로 (ALB TG 헬스체크 + k8s probe + 리스너 규칙에 공용)."
}

variable "images_prefix" {
  type        = string
  default     = "/images"
  description = "이미지 다운로드 경로 prefix. CloudFront 캐시 동작과 URI rewrite 함수에 공용."
}

variable "container_port" {
  type        = number
  default     = 8080
  description = "앱 컨테이너 포트. Deployment/probe/Service/ALB TG/SG 에 공용 (한 곳만 바꾸면 전부 반영)."
}

# ---------- WAF: "관찰 → 차단" (기본은 아무것도 차단하지 않음) ----------
# 대회날 트래픽이 시작되면 tuning/waf_header_stats.py 로 비정상 패턴을 관찰한 뒤,
# 아래 변수에 패턴만 추가하고 terraform apply 하면 즉시 차단된다 (waf.tf 수정 불필요).

variable "waf_custom_rule_action" {
  type        = string
  default     = "block"
  description = "커스텀 차단 룰의 액션. 오차단이 걱정되면 \"count\"로 먼저 넣고 WAF 로그로 확인 후 \"block\"으로 변경."
  validation {
    condition     = contains(["block", "count"], var.waf_custom_rule_action)
    error_message = "waf_custom_rule_action must be \"block\" or \"count\"."
  }
}

# 아래 기본값들은 연습 트래픽으로 검증된 "오탐 0" 패턴 — 정상 트래픽(hey/Go/curl/브라우저,
# 표준 헤더, JSON body)에는 절대 안 나온다. 처리율은 전 기간 누적 %이므로 처음부터 켠다.
# 대회날 오탐이 의심되면 해당 변수만 [] / false 로 바꿔 apply (즉시 해제).

variable "waf_blocked_user_agents" {
  type        = list(string)
  default     = ["sqlmap", "nikto", "nmap", "masscan", "acunetix", "havij", "nuclei", "wpscan", "dirbuster", "gobuster", "attack"]
  description = "User-Agent 에 이 문자열이 포함되면 403 (대소문자 무시). 스캐너/공격도구 이름 — 정상 UA(hey/Go/curl/Mozilla)와 겹치지 않음."
}

variable "waf_blocked_headers" {
  type        = list(string)
  default     = ["x-junk"]
  description = "이 헤더가 존재하기만 하면 403. 소문자로 입력. 대회날 새 쓰레기 헤더 발견 시 추가. 예: [\"x-junk\",\"x-debug\"]"
}

variable "waf_blocked_header_values" {
  type = list(object({
    header = string # 헤더 이름 (소문자)
    value  = string # 이 문자열이 포함되면 차단 (대소문자 무시)
  }))
  default     = []
  description = "특정 헤더 값에 문자열이 포함되면 403. 예: [{ header = \"referer\", value = \"evil.com\" }]"
}

variable "waf_blocked_query_patterns" {
  type        = list(string)
  default     = []
  description = "쿼리스트링을 URL 디코딩/소문자화한 뒤 이 문자열이 포함되면 403. 관찰 후 고위험 토큰만 추가 (예: [\"/etc/passwd\", \"{{\"])."
}

variable "waf_blocked_body_patterns" {
  type        = list(string)
  default     = ["$ne", "$gt", "$where", "sleep(", "benchmark("]
  description = "요청 body 에 이 문자열이 포함되면 403 (대소문자 무시). NoSQL/SQL 인젝션 토큰 — 정상 JSON body 에 절대 없음."
}

variable "waf_block_private_xff" {
  type        = bool
  default     = true
  description = "X-Forwarded-For 에 루프백/사설/메타데이터 IP(127. 10. 192.168. 172.16-31. 169.254.)가 들어간 요청을 403. 채점 트래픽은 공인 IP 직결이라 안전."
}

variable "is_windows" {
  type        = bool
  default     = true
  description = "Set true when running terraform from Windows PowerShell (no bash). build.tf then uses PowerShell instead of /bin/sh for the docker build/push step. CloudShell/Linux?먯꽌 ?ㅽ뻾 ??-var is_windows=false 瑜?吏?뺥븯?몄슂."
}