# 기본 리전: 서울 (과제: 모든 리소스는 ap-northeast-2)
provider "aws" {
  region = var.region
}

# CloudFront 자체는 글로벌이지만 aws_cloudfront_* 리소스는 기본 provider 로 생성 가능.
# (CLOUDFRONT 스코프 WAF 가 필요하면 us-east-1 alias 를 쓰지만 vf 과제엔 WAF 없음)
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# kubernetes/helm provider 는 root 에서 제거됨.
# 클러스터/노드그룹/ALB 등 AWS 리소스만 root 에서 관리하므로 import/plan/destroy 가
# 클러스터 생성 이전이라도 깨끗하게 동작한다.
# 모든 kubernetes_*/helm_release/TargetGroupBinding 은 ./k8s 스테이지에서 적용한다.
# (k8s/providers.tf 가 data "aws_eks_cluster" 로 클러스터를 이름 조회하여 인증)
