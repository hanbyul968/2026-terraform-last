# ═══════════════════════════════════════════════════════════════
# Bastion (선택)  — VPC 내부에서 kubectl / terraform apply 용
#   EKS 가 Fully Private 이므로, public access 를 끈 상태로 채점하려면
#   VPC 내부(Bastion)에서 k8s 리소스를 다뤄야 한다.
#   t3.medium / Public(hub) 서브넷 / SSH(22)만 / Elastic IP
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
  name        = "wsc2026-bastion-sg"
  description = "Bastion - SSH only"
  vpc_id      = aws_vpc.this.id
  ingress {
    description = "SSH"
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
  tags = { Name = "wsc2026-bastion-sg" }
}

resource "aws_iam_role" "bastion" {
  name = "wsc2026-bastion-role"
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
  name = "wsc2026-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.hub_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "optional"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/files/bastion-userdata.sh.tftpl", {
    ssh_password = "Skill53##"
    region       = local.region
    cluster_name = local.cluster_name
  })

  tags = { Name = "wsc2026-bastion" }
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "wsc2026-bastion-eip" }
}

# Bastion -> EKS API 접근 허용
resource "aws_security_group_rule" "bastion_to_eks_api" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description              = "Bastion to EKS API"
}

# Bastion role -> ClusterAdmin
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.bastion]
}
