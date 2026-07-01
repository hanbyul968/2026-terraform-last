# ───────────────────────────────────────────────────────────────
# 대회 중 값이 바뀔 수 있는 항목을 이 파일과 locals.tf 로 모았다.
# "어떤 값이 바뀌면 어디를 고치나"는 README.md 의 변경 매핑표 참고.
# ───────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS 리전. 과제 기본값 ap-northeast-2(서울)."
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "가용영역 2개. 채점이 sub-a, sub-b 순서를 기대하므로 [a, b] 순서 중요."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b"]
}

# ── 비번호 (S3 버킷 이름에 사용) ──
# S3 Bucket : wsc2026-static-<임의 영문 4자리>-<본인 비번호>-bucket
variable "bi_number" {
  description = "본인 비번호. S3 버킷 이름에 들어감. 고정 default 없음 → apply 시 입력(-var/프롬프트)."
  type        = string
}

variable "bucket_rand" {
  description = "S3 버킷 이름의 임의 영문 4자리."
  type        = string
  default     = "abcd"
}

# ── CDN 배포 게이트 ──
# CloudFront 는 k8s Ingress 가 만든 ALB(data.aws_lb.app)를 origin 으로 참조하므로,
# 최초 root apply 시엔 ALB 가 아직 없어 실패한다. 그래서 3단계로 나눈다:
#   1) root apply -var=deploy_cdn=false  (CDN 제외한 전 인프라 + ALB SG)
#   2) k8s apply                          (Ingress -> ALB 생성)
#   3) root apply -var=deploy_cdn=true    (ALB 존재 -> CDN 생성)  ※ run.sh 자동 처리
variable "deploy_cdn" {
  description = "CloudFront(및 ALB data 조회) 생성 여부. ALB 는 k8s 가 만들므로 1차 apply 에선 false(기본). CDN 은 run.sh 3단계에서 -var=deploy_cdn=true 로 생성."
  type        = bool
  default     = false
}

# ── EKS 클러스터 역할 재사용 ──
# reuse_kms=true(잠긴 eks 키 재사용) 계정에선 그 키 정책이 기존 wsc2026-eks-cluster-role
# 에게만 grant 를 허용하므로 역할도 재사용해야 한다(true). 깨끗한 계정/대회는 false(신규 생성, 기본).
variable "reuse_eks_cluster_role" {
  type    = bool
  default = false
}

# ── 채점 IAM principal (EKS ClusterAdmin access entry) ──
# CloudShell 등 채점 신원의 role/user ARN. 비우면 access entry 생성 안 함(bastion 역할=생성자는 이미 admin).
# !! STS assumed-role 세션 ARN 은 사용 불가 !!
variable "grader_principal_arn" {
  description = "채점 IAM principal ARN(role/user). 비우면 access entry 생성 안 함."
  type        = string
  default     = ""
}

# ── EKS ──
variable "cluster_version" {
  description = "EKS 클러스터 버전. 과제 1.35."
  type        = string
  default     = "1.35"
}

# 과제: 모든 클러스터는 Fully Private. 채점(4-1)은 public=False, private=True 기대.
# 단, Windows/로컬에서 k8s·helm 을 apply 하려면 apply 동안엔 public 을 잠깐 켜야 한다.
# 절차: (1) true 로 apply -> (2) false 로 재apply.  Bastion 내부에서 apply 하면 계속 false 가능.
variable "eks_public_access" {
  description = "EKS API 퍼블릭 접근. 채점 시점엔 반드시 false."
  type        = bool
  default     = true
}

# Kubernetes 내부 도메인 (과제: *.cluster.local -> *.wsc2026.skills.local)
variable "cluster_dns_domain" {
  description = "클러스터 내부 DNS 도메인."
  type        = string
  default     = "wsc2026.skills.local"
}

# ── Grafana ──
variable "grafana_admin_password" {
  description = "Grafana admin 패스워드 (과제 11)."
  type        = string
  default     = "Skills$#$@!"
}

# ── KMS 키 관리 주체 ──
# CMK 정책에 root / kms:* 를 쓸 수 없으므로(채점 check_kms),
# 키 관리 권한을 부여할 '실제 배포 주체'의 ARN 을 명시한다.
# 기본값은 terraform 을 실행하는 자격증명(caller) ARN.
#   * 만약 assumed-role 세션으로 apply 한다면 세션 ARN 이 아니라
#     해당 'role ARN'(arn:aws:iam::<acct>:role/<name>) 으로 바꿔줄 것.
variable "kms_admin_arn" {
  description = "CMK 관리 권한을 가질 IAM principal ARN. 비우면 caller ARN 사용."
  type        = string
  default     = ""
}
