# 이 스테이지(로컬 1단계)가 이제 wsc-vpc + 공유 KMS + Flow Logs 까지 생성한다.
# (bastion 이 같은 wsc-vpc 안에 위치해, EKS private-only 전환 후에도 클러스터에 접근 가능)
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  region       = var.region
  partition    = data.aws_partition.current.partition
  cluster_name = "wsc-eks-cluster"
}
