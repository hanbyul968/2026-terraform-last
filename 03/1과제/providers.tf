# 기본 리전: 서울 (과제 유의사항 9: 모든 리소스 ap-northeast-2)
provider "aws" {
  region = var.region
}

# CloudFront / WAF(CLOUDFRONT scope) 는 us-east-1 에서만 생성 가능
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# ── k8s / helm provider 는 이 root 에 두지 않는다 ──
# kubernetes_*/helm_release/finalize 리소스는 별도 스테이지(./k8s)로 분리했다.
# 이렇게 하면 클러스터가 아직 없어도 root 의 import/plan/destroy 가 깨끗하게 동작한다.
# (apply 순서: 1) 이 root → 2) ./k8s)
