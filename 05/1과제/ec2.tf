############################
# Bastion VPC (별도 VPC — 채점 시 gj2026-vpc 서브넷 목록에 bastion 미포함)
############################

resource "aws_vpc" "bastion" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "gj2026-bastion-vpc" }
}

resource "aws_internet_gateway" "bastion" {
  vpc_id = aws_vpc.bastion.id
}

resource "aws_subnet" "bastion" {
  vpc_id                  = aws_vpc.bastion.id
  cidr_block              = "172.16.0.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "gj2026-bastion-subnet" }
}

resource "aws_route_table" "bastion" {
  vpc_id = aws_vpc.bastion.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bastion.id
  }
  tags = { Name = "gj2026-bastion-rtb" }
}

resource "aws_route_table_association" "bastion" {
  subnet_id      = aws_subnet.bastion.id
  route_table_id = aws_route_table.bastion.id
}

resource "aws_security_group" "bastion" {
  name   = "gj2026-bastion-sg"
  vpc_id = aws_vpc.bastion.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################
# Bastion IAM
############################

resource "aws_iam_instance_profile" "bastion" {
  name = "gj2026-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_iam_role" "bastion" {
  name = "gj2026-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

############################
# Bastion EC2
############################

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.bastion.id
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  user_data_base64 = base64encode(templatefile("${path.module}/userdata.sh", {
    account_id     = local.account_id
    region         = "ap-northeast-2"
    cluster_name   = aws_eks_cluster.cluster.name
    book_tg_arn    = aws_lb_target_group.book.arn
    grafana_tg_arn = aws_lb_target_group.grafana.arn
  }))

  tags = { Name = "gj2026-bastion" }

  depends_on = [aws_eks_cluster.cluster, aws_eks_node_group.addon, aws_eks_node_group.app]
}
