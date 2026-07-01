# =============================================================================
# 3. 네트워크 구성 (이제 이 스테이지 = bastion 단계에서 생성한다)
#  - VPC 10.0.0.0/16
#  - Public Subnet 2개 (서로 다른 AZ)
#  - Internet Gateway
#  - Public Route Table (0.0.0.0/0 -> IGW), 두 서브넷에 연결
#
#  ※ 01 모델을 따른다: bastion 스테이지가 "진짜 VPC/서브넷/IGW/라우팅"을 소유하고,
#    같은 VPC 의 퍼블릭 서브넷에 Bastion 을 띄운다. root(ECS) 스테이지는
#    data.* 로 이 네트워크를 조회해서만 참조한다(data.tf).
#  ※ Name 태그는 root 의 data 조회 키다. root 와 bastion 은 동일한 player_id 를
#    공유하므로(userdata 가 root tfvars 에 주입) 조회가 항상 일치한다.
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.player_id}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.player_id}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.player_id}-public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.player_id}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
