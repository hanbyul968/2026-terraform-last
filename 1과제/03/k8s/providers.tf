terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = ">= 5.80" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.region
}

# ── 클러스터는 1단계(root)에서 이미 생성됨 → 이름으로 조회(관리 리소스 의존 X) ──
# 이 덕분에 root 에서는 kubernetes/helm provider 가 없어 import/plan/destroy 가 깨끗하고,
# 이 k8s 스테이지는 클러스터가 존재하는 시점(2단계)에만 실행되므로 data 조회가 항상 성공한다.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}
data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
