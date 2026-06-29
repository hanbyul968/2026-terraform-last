###############################################################################
# Bootstrap (LOCAL apply)
# 로컬 PC(Windows)에서 실행되며, Docker/Terraform이 설치된 Linux Bastion을 띄운다.
# Bastion에는 ../main 구성과 app 바이너리가 업로드되고, 관리자 권한 인스턴스
# 프로파일이 부여된다. 실제 채점 대상 인프라(skills-book-*)는 Bastion 안에서
# `terraform apply` 로 생성한다.
###############################################################################

data "aws_availability_zones" "az" { state = "available" }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# --- Bastion 전용 최소 네트워크 (채점 대상 skills-book-vpc 와 분리) ---------
resource "aws_vpc" "bastion" {
  cidr_block           = "10.255.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "skills-bastion-vpc" }
}

resource "aws_subnet" "bastion" {
  vpc_id                  = aws_vpc.bastion.id
  cidr_block              = "10.255.0.0/24"
  availability_zone       = data.aws_availability_zones.az.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "skills-bastion-public" }
}

resource "aws_internet_gateway" "bastion" {
  vpc_id = aws_vpc.bastion.id
  tags   = { Name = "skills-bastion-igw" }
}

resource "aws_route_table" "bastion" {
  vpc_id = aws_vpc.bastion.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bastion.id
  }
  tags = { Name = "skills-bastion-rt" }
}

resource "aws_route_table_association" "bastion" {
  subnet_id      = aws_subnet.bastion.id
  route_table_id = aws_route_table.bastion.id
}

resource "aws_security_group" "bastion" {
  name   = "skills-bastion-sg"
  vpc_id = aws_vpc.bastion.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "skills-bastion-sg" }
}

# --- SSH Key Pair -----------------------------------------------------------
resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion" {
  key_name   = "skills-bastion-key"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "local_file" "bastion_key" {
  content         = tls_private_key.bastion.private_key_pem
  filename        = "${path.module}/bastion-key.pem"
  file_permission = "0600"
}

# --- Bastion IAM (관리자 권한: main 스테이지 전체 리소스를 생성) -------------
resource "aws_iam_role" "bastion" {
  name = "skills-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_admin" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "skills-bastion-profile"
  role = aws_iam_role.bastion.name
}

# --- Bastion EC2 ------------------------------------------------------------
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.bastion.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  key_name               = aws_key_pair.bastion.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  depends_on = [aws_internet_gateway.bastion]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.bastion.private_key_pem
    host        = self.public_ip
    timeout     = "5m"
  }

  # 1) main 스테이지(채점 대상 구성 + app 바이너리)를 Bastion으로 업로드
  provisioner "file" {
    source      = "${path.module}/../main"
    destination = "/home/ec2-user"
  }

  # 2) Docker / Terraform 설치 + tfvars 작성 + apply 헬퍼 생성
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '== installing docker =='",
      "sudo dnf install -y docker git unzip",
      "sudo systemctl enable --now docker",
      "echo '== installing terraform =='",
      "TF_VER=1.9.8",
      "curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/$${TF_VER}/terraform_$${TF_VER}_linux_amd64.zip",
      "sudo unzip -o /tmp/tf.zip -d /usr/local/bin",
      "terraform -version",
      "echo '== writing terraform.tfvars =='",
      "cat > /home/ec2-user/main/terraform.tfvars <<EOF",
      "bibunho             = \"${var.bibunho}\"",
      "origin_verify_value = \"${var.origin_verify_value}\"",
      "EOF",
      "echo '== writing apply helper =='",
      "cat > /home/ec2-user/apply.sh <<'EOF'",
      "#!/bin/bash",
      "set -e",
      "cd /home/ec2-user/main",
      "terraform init -input=false",
      "terraform apply -input=false -auto-approve",
      "echo",
      "echo '=== OUTPUTS ==='",
      "terraform output",
      "EOF",
      "chmod +x /home/ec2-user/apply.sh",
      "echo 'Bastion ready. SSH in and run: ./apply.sh'"
    ]
  }

  tags = { Name = "skills-bastion" }
}
