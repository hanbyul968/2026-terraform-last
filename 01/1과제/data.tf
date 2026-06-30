# wsc-vpc / 서브넷 / 공유 KMS 는 1단계(bastion 스테이지)에서 생성된다.
# root(2단계, bastion 에서 apply)는 이름/alias 로 조회해 참조한다.
data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["wsc-vpc"]
  }
}

data "aws_subnet" "pub_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-pub-sn-a"]
  }
}

data "aws_subnet" "pub_b" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-pub-sn-b"]
  }
}

data "aws_subnet" "priv_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-priv-sn-a"]
  }
}

data "aws_subnet" "priv_b" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-priv-sn-b"]
  }
}

data "aws_kms_key" "main" {
  key_id = "alias/wsc-2026-key"
}
