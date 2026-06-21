###############################################################################
# Module 1: DocumentDB based NoSQL Application (ap-northeast-2)
###############################################################################

data "aws_availability_zones" "seoul" {
  provider = aws.seoul
  state    = "available"
}

data "aws_ami" "al2023_seoul" {
  provider    = aws.seoul
  most_recent = true
  owners      = ["amazon"]
  filter {
    name = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
  filter {
    name = "state"
    values = ["available"]
  }
}

resource "aws_vpc" "m1" {
  provider             = aws.seoul
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "m1_public" {
  provider                = aws.seoul
  vpc_id                  = aws_vpc.m1.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = data.aws_availability_zones.seoul.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "m1_private" {
  count             = 2
  provider          = aws.seoul
  vpc_id            = aws_vpc.m1.id
  cidr_block        = "10.1.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.seoul.names[count.index]
}

resource "aws_internet_gateway" "m1" {
  provider = aws.seoul
  vpc_id   = aws_vpc.m1.id
}

resource "aws_route_table" "m1_public" {
  provider = aws.seoul
  vpc_id   = aws_vpc.m1.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m1.id
  }
}

resource "aws_route_table_association" "m1_public" {
  provider       = aws.seoul
  subnet_id      = aws_subnet.m1_public.id
  route_table_id = aws_route_table.m1_public.id
}

resource "aws_security_group" "m1_ec2" {
  provider = aws.seoul
  vpc_id   = aws_vpc.m1.id
  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "m1_docdb" {
  provider = aws.seoul
  vpc_id   = aws_vpc.m1.id
  ingress {
    from_port = 27017
    to_port = 27017
    protocol = "tcp"
    security_groups = [aws_security_group.m1_ec2.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# KMS
resource "aws_kms_key" "m1_docdb" { provider = aws.seoul }
resource "aws_kms_alias" "m1_docdb" {
  provider      = aws.seoul
  name          = "alias/skills-nosql-docdb"
  target_key_id = aws_kms_key.m1_docdb.key_id
}

# DocumentDB
resource "aws_docdb_subnet_group" "m1" {
  provider   = aws.seoul
  name       = "skills-nosql-docdb-sg"
  subnet_ids = aws_subnet.m1_private[*].id
}

resource "aws_docdb_cluster_parameter_group" "m1" {
  provider = aws.seoul
  family   = "docdb5.0"
  name     = "skills-nosql-params"
  parameter {
    name  = "tls"
    value = "enabled"
  }
}

resource "aws_docdb_cluster" "m1" {
  provider                        = aws.seoul
  cluster_identifier              = "skills-nosql-docdb-cluster"
  engine                          = "docdb"
  master_username                 = "skillsadmin"
  master_password                 = var.docdb_password
  db_subnet_group_name            = aws_docdb_subnet_group.m1.name
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.m1.name
  vpc_security_group_ids          = [aws_security_group.m1_docdb.id]
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.m1_docdb.arn
  backup_retention_period         = 1
  skip_final_snapshot             = true
}

resource "aws_docdb_cluster_instance" "m1" {
  provider           = aws.seoul
  identifier         = "skills-nosql-docdb-instance-1"
  cluster_identifier = aws_docdb_cluster.m1.id
  instance_class     = "db.t3.medium"
}

# Secrets Manager
resource "aws_secretsmanager_secret" "m1" {
  provider = aws.seoul
  name     = "skills-nosql-docdb-secret"
}

resource "aws_secretsmanager_secret_version" "m1" {
  provider  = aws.seoul
  secret_id = aws_secretsmanager_secret.m1.id
  secret_string = jsonencode({
    username = "skillsadmin"
    password = var.docdb_password
    host     = aws_docdb_cluster.m1.endpoint
  })
}

# EC2 IAM
resource "aws_iam_role" "m1_ec2" {
  name = "skills-nosql-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "m1_ssm" {
  role       = aws_iam_role.m1_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "m1_secrets" {
  role       = aws_iam_role.m1_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}
resource "aws_iam_instance_profile" "m1" {
  name = "skills-nosql-ec2-profile"
  role = aws_iam_role.m1_ec2.name
}

# EC2 Client
resource "aws_instance" "m1_client" {
  provider               = aws.seoul
  ami                    = data.aws_ami.al2023_seoul.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.m1_public.id
  vpc_security_group_ids = [aws_security_group.m1_ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.m1.name

  user_data = <<-USERDATA
#!/bin/bash
set -ex
dnf install -y python3.11 python3.11-pip
ln -sf /usr/bin/python3.11 /usr/bin/python3

mkdir -p /opt/skills-nosql
aws secretsmanager get-secret-value --secret-id skills-nosql-docdb-secret --region ap-northeast-2 --query SecretString --output text > /tmp/secret.json
DOCDB_HOST=$(python3 -c "import json;print(json.load(open('/tmp/secret.json'))['host'])")
DOCDB_USER=$(python3 -c "import json;print(json.load(open('/tmp/secret.json'))['username'])")
DOCDB_PASS=$(python3 -c "import json;print(json.load(open('/tmp/secret.json'))['password'])")

cat > /opt/skills-nosql/env.sh <<ENVEOF
export DOCDB_HOST=$DOCDB_HOST
export DOCDB_USER=$DOCDB_USER
export DOCDB_PASS=$DOCDB_PASS
export DOCDB_PORT=27017
export DOCDB_TLS=true
export DOCDB_CA_PATH=/opt/skills-nosql/global-bundle.pem
ENVEOF

# App files are placed via S3 or manually
# For now, create placeholder - actual files uploaded separately
USERDATA

  tags = { Name = "skills-nosql-client-ec2" }
}
