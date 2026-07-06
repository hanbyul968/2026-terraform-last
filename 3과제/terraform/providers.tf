provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

# CloudFront ACM cert (if needed) is in us-east-1.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# kubernetes/helm/kubectl provider 는 EKS 클러스터에 의존한다.
# 클러스터가 아직 없을 때(var.k8s_provider_ready=false)는 local.eks_host/eks_ca 가
# 더미 값이 되어 "Invalid provider configuration" 에러 없이 import/클러스터 생성이 가능하다.
provider "kubernetes" {
  host                   = local.eks_host
  cluster_ca_certificate = local.eks_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = concat(["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.region], local.profile_args)
  }
}

provider "helm" {
  kubernetes {
    host                   = local.eks_host
    cluster_ca_certificate = local.eks_ca

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = concat(["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.region], local.profile_args)
    }
  }
}

provider "kubectl" {
  host                   = local.eks_host
  cluster_ca_certificate = local.eks_ca
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = concat(["eks", "get-token", "--cluster-name", local.eks_cluster_name, "--region", var.region], local.profile_args)
  }
}