# 기본 리전: 서울. (과제: 모든 리소스는 ap-northeast-2)
provider "aws" {
  region = var.region
}

# CloudFront / WAF(CLOUDFRONT scope) 는 us-east-1 에 만들어야 한다.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# NOTE: kubernetes/helm provider 는 2단계(k8s/) 스테이지로 분리되었다.
#   root 는 순수 AWS provider 만 사용하므로, 클러스터가 없는 상태에서도
#   terraform import / plan / destroy 가 깨끗하게 동작한다.
#   k8s/helm 리소스는 root apply 후 04\1과제\k8s\ 에서 적용한다.
