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

# EKS 클러스터에 k8s/helm provider 연결.
# apply 시점엔 클러스터 endpoint 가 public(임시) 으로 열려 있어야 Windows 에서 접근 가능.
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
