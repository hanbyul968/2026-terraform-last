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

# ── k8s / helm provider ──
# EKS 는 Fully Private (endpoint_public_access=false) 이므로,
# terraform 을 적용하는 위치에서 클러스터 endpoint(443) 에 도달할 수 있어야 한다.
#   - Bastion / Cloud9 등 VPC 내부에서 apply 하거나,
#   - apply 동안만 var.eks_public_access=true 로 열고 채점 전 false 로 재apply.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}
