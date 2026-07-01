# =============================================================================
# 네트워크(진짜 VPC/서브넷)는 1단계(bastion 스테이지)에서 생성된다.
# root(ECS, bastion 에서 apply)는 Name 태그로 조회해 참조만 한다.
#  - bastion 스테이지의 network.tf 가 생성한 리소스를 그대로 가리킨다.
#  - root 와 bastion 은 동일한 player_id 를 공유(userdata 가 root tfvars 에 주입)하므로
#    아래 조회 키가 항상 일치한다.
# =============================================================================

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["${var.player_id}-vpc"]
  }
}

# 퍼블릭 서브넷 2개 (ALB / ECS 서비스가 사용)
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.player_id}-public-subnet-*"]
  }
}
