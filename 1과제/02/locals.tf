locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.region

  # ── 리소스 이름 (과제 고정값) ──────────────────────────────
  cluster_name = "wskorea26-cluster"
  ecr_repo     = "wskorea26-book-repo"
  image_tag    = "stable" # 과제 6: 이미지 태그 stable
  table_name   = "wskorea26-data-table"
  gsi_name     = "concert_name-created_at-index" # 조회(최신순) 용 GSI

  # 채점 8-1 버킷명: wskorea26-concert-bucket-<비번호>
  bucket_name = "wskorea26-concert-bucket-${var.bi_number}"

  registry  = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image_url = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/${local.ecr_repo}:${local.image_tag}"

  namespace = "wskorea26" # 과제 8: 애플리케이션 네임스페이스

  # ── VPC / Subnet (Reference01) ─────────────────────────────
  vpc_cidr = "172.16.0.0/16"
  subnets = {
    pub_c  = { cidr = "172.16.1.0/24", az = var.azs[0] }   # wskorea26-pub-subnet-c
    pub_d  = { cidr = "172.16.2.0/24", az = var.azs[1] }   # wskorea26-pub-subnet-d
    priv_c = { cidr = "172.16.201.0/24", az = var.azs[0] } # wskorea26-priv-subnet-c
    priv_d = { cidr = "172.16.202.0/24", az = var.azs[1] } # wskorea26-priv-subnet-d
  }
}
