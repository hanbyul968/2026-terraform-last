locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.region
  partition  = data.aws_partition.current.partition

  cluster_name = "wsc-eks-cluster"
  ecr_repo     = "book-ecr"
  table_name   = "wsc-dynamo"
  bucket_name  = "wsc-2026-bucket-${var.competitor_number}-${local.account_id}"

  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image    = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/book-ecr:latest"
}
