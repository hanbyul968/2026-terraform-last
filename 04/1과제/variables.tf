# ───────────────────────────────────────────────────────────────
# 대회 중 값이 바뀔 수 있는 항목은 가급적 이 파일의 변수로 모아두었다.
# 자세한 "값이 바뀌면 어디를 고치나"는 README.md 의 변경 매핑표 참고.
# ───────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS 리전. 과제 기본값 ap-northeast-2(서울)."
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "사용할 가용영역 2개. 채점이 a, c 순서를 기대하므로 순서 중요."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "bi_number" {
  description = "비번호 (태그용, 선택)."
  type        = string
  default     = ""
}

# ── Bastion / Node 공통 SSH 비밀번호 (과제 고정값) ──
variable "ssh_password" {
  description = "Bastion 및 NodeGroup SSH 패스워드. 과제: Skill53##"
  type        = string
  default     = "Skill53##"
}

# ── EKS API 퍼블릭 엔드포인트 ──
# 과제 채점(6-1-A)은 public=False, private=True 를 기대한다.
# 단, Windows 로컬에서 k8s/helm 을 apply 하려면 apply 동안엔 public 이 켜져 있어야 한다.
# 절차: (1) true 로 전체 apply  ->  (2) false 로 바꿔 재apply (또는 finalize 가 자동 비활성화)
variable "eks_public_access" {
  description = "EKS API 퍼블릭 접근. 채점 전엔 false 여야 함."
  type        = bool
  default     = true
}

# ── 쿠버네티스 클러스터 도메인 (과제: *.cluster.local -> *.wsc.local) ──
variable "cluster_dns_domain" {
  description = "클러스터 내부 DNS 도메인. 과제 변경값 wsc.local"
  type        = string
  default     = "wsc.local"
}

# ── 채점자 principal ARN (EKS access entry) ──
# Bastion 이 클러스터 생성자이며 bootstrap_cluster_creator_admin_permissions=true 로
# 이미 ClusterAdmin 이다. 여기에 data.aws_caller_identity.current.arn 을 쓰면 STS 세션
# ARN(assumed-role/.../session)이라 aws_eks_access_entry 가
# 'InvalidParameterException: principalArn format is not valid' 로 실패한다.
# 따라서 기본은 빈값(=access entry 미생성)으로 두고, 별도 채점자 IAM Role/User ARN 을
# 넘기고 싶을 때만 값을 설정한다.
variable "grader_principal_arn" {
  description = "EKS ClusterAdmin access entry 를 만들 채점자 IAM principal ARN. 빈값이면 생성하지 않음."
  type        = string
  default     = ""
}
