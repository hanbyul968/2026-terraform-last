# ═══════════════════════════════════════════════════════════════
# Bastion  (과제 5)
#   - t3.medium / Amazon Linux 2023 / Public Subnet
#   - 재시작해도 IP 고정 => Elastic IP
#   - 외부에서 SSH(22)만 허용
#   - SSH Password 방식 (ec2-user / Skill53##), 채점은 sshpass 사용
#   - awscli 가 Admin 권한 => AdministratorAccess instance profile
#   - 패키지: awscliv2, jq, curl, ping, kubectl, eksctl
#   - Tag: Name=wsc-bastion
# ═══════════════════════════════════════════════════════════════

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "wsc-bastion-sg"
  description = "Bastion - SSH only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from anywhere"
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
  tags = { Name = "wsc-bastion-sg" }
}

resource "aws_iam_role" "bastion" {
  name = "wsc-bastion-role"
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
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "wsc-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "optional"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/files/bastion-userdata.sh.tftpl", {
    ssh_password = var.ssh_password
    region       = local.region
    cluster_name = local.cluster_name
  })

  tags = { Name = "wsc-bastion" }
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "wsc-bastion-eip" }
}

# Bastion -> EKS API 접근 허용 (cluster SG ingress 443)
resource "aws_security_group_rule" "bastion_to_eks_api" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description              = "Bastion to EKS API"
}
