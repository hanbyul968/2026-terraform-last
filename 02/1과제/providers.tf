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

# EKS 클러스터에 k8s/helm provider 연결.
# 클러스터 endpoint 가 public 으로 열려 있어야 CloudShell/로컬에서 apply 가능.
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
