# ───────────────────────────────────────────────────────────────
# 대회 중 값이 바뀔 수 있는 항목은 가급적 이 파일 + locals.tf 로 모았다.
# "어떤 값이 바뀌면 어디를 고치나"는 README.md 의 변경 매핑표 참고.
# ───────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS 리전. 과제 고정값 ap-northeast-2(서울)."
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "사용할 가용영역 2개. Reference01 이 c, d 를 사용하므로 순서/문자 중요."
  type        = list(string)
  default     = ["ap-northeast-2c", "ap-northeast-2d"]
}

# ── 선수 비번호 ────────────────────────────────────────────────
# S3 버킷명 wskorea26-concert-bucket-<비번호> 에 사용. 채점 예시: 103
# !! 대회 시작하면 반드시 본인 비번호로 변경 !!
variable "bi_number" {
  description = "선수 비번호. S3 버킷 suffix 등에 사용."
  type        = string
  default     = "000"
}

# ── CloudFront -> ALB 식별 헤더 (과제 11/10) ──
variable "cf_origin_verify" {
  description = "CloudFront 가 ALB origin 으로 보낼 때 붙이는 X-Origin-Verify 값."
  type        = string
  default     = "wskorea26-cf"
}

# ── CloudFront -> S3 식별 헤더 값 (과제 11, 채점 8-3 = true) ──
variable "s3_access_header_value" {
  description = "CloudFront 가 S3 origin 으로 보낼 wskorea26-s3-access 헤더 값."
  type        = string
  default     = "true"
}

# ── Grafana 관리자 (채점 10-1: admin / wsk2026!) ──
variable "grafana_admin_user" {
  description = "Grafana 관리자 ID. 채점 로그인: admin"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Grafana 관리자 PW. 채점 로그인: wsk2026!"
  type        = string
  default     = "wsk2026!"
}

# ── EKS 버전 (과제 8) ──
variable "eks_version" {
  description = "EKS 클러스터 버전. 과제 고정값 1.35"
  type        = string
  default     = "1.35"
}

# ── 노드 인스턴스 타입 (과제 8) ──
variable "node_instance_type" {
  description = "addon/app 노드그룹 인스턴스 타입. 과제 고정값 t3.medium"
  type        = string
  default     = "t3.medium"
}
