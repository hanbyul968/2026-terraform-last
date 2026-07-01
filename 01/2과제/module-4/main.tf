terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = ">= 5.80" }
    tls   = { source = "hashicorp/tls", version = ">= 4.0" }
    local = { source = "hashicorp/local", version = ">= 2.0" }
  }
}

provider "aws" { region = "ap-southeast-1" }

locals { azs = ["ap-southeast-1a", "ap-southeast-1b"] }

resource "aws_vpc" "vpn" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc2026-vpn-vpc" }
}

resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.vpn.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-pub-sn-a" }
}

resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.vpn.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.azs[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-pub-sn-b" }
}

resource "aws_subnet" "vpn_a" {
  vpc_id            = aws_vpc.vpn.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = local.azs[0]
  tags              = { Name = "wsc2026-vpn-sn-a" }
}

resource "aws_subnet" "vpn_b" {
  vpc_id            = aws_vpc.vpn.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = local.azs[1]
  tags              = { Name = "wsc2026-vpn-sn-b" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.vpn.id
  tags   = { Name = "wsc2026-vpn-igw" }
}

resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "wsc2026-vpn-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.vpn.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "wsc2026-pub-rt" }
}

resource "aws_route_table" "vpn" {
  vpc_id = aws_vpc.vpn.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "wsc2026-vpn-rt" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "vpn_a" {
  subnet_id      = aws_subnet.vpn_a.id
  route_table_id = aws_route_table.vpn.id
}
resource "aws_route_table_association" "vpn_b" {
  subnet_id      = aws_subnet.vpn_b.id
  route_table_id = aws_route_table.vpn.id
}

# EC2
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

resource "aws_security_group" "ec2" {
  name   = "vpn-ec2-sg"
  vpc_id = aws_vpc.vpn.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16", "172.16.0.0/22"]
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/16", "172.16.0.0/22"]
  }
}

resource "aws_instance" "vpn_ec2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.vpn_b.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.vpn_ec2.key_name
  tags                   = { Name = "vpn-ec2" }
}

# ---- SSH key pair for the VPN connect test (rubric 14-2: ssh -i <key> ec2-user@<ip>) ----
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "vpn_ec2" {
  key_name   = "vpn-ec2-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# Write the private key next to the module so the competitor can `ssh -i vpn-ec2-key.pem ...`
# after connecting through the Client VPN. (Also exposed as a sensitive output.)
resource "local_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/vpn-ec2-key.pem"
  file_permission = "0600"
}

# TLS Certificates
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  subject { common_name = "wsc-ca" }
  allowed_uses = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  subject { common_name = "cve.wsc" }
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem      = tls_cert_request.server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 87600
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem
  subject { common_name = "client.wsc" }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem      = tls_cert_request.client.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 87600
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

# ACM
resource "aws_acm_certificate" "server" {
  private_key       = tls_private_key.server.private_key_pem
  certificate_body  = tls_locally_signed_cert.server.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem
  tags              = { Name = "cve.wsc" }
}

resource "aws_acm_certificate" "client" {
  private_key       = tls_private_key.client.private_key_pem
  certificate_body  = tls_locally_signed_cert.client.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem
  tags              = { Name = "client.wsc" }
}

# Client VPN
resource "aws_security_group" "vpn" {
  name   = "wsc-vpn-sg"
  vpc_id = aws_vpc.vpn.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "wsc-vpn"
  server_certificate_arn = aws_acm_certificate.server.arn
  client_cidr_block      = "172.16.0.0/22"
  transport_protocol     = "udp"
  vpn_port               = 1194
  split_tunnel           = true
  vpc_id                 = aws_vpc.vpn.id
  security_group_ids     = [aws_security_group.vpn.id]

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.client.arn
  }

  connection_log_options { enabled = false }

  tags = { Name = "wsc-vpn" }
}

resource "aws_ec2_client_vpn_network_association" "vpn_b" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = aws_subnet.vpn_b.id
}

resource "aws_ec2_client_vpn_authorization_rule" "all" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = "10.0.0.0/16"
  authorize_all_groups   = true
}

# ---- Outputs (VPN connect test helpers) ----
output "vpn_ec2_private_ip" {
  description = "vpn-ec2 private IP - SSH target after connecting via Client VPN"
  value       = aws_instance.vpn_ec2.private_ip
}

output "client_vpn_endpoint_id" {
  description = "Client VPN endpoint id (download .ovpn config from here)"
  value       = aws_ec2_client_vpn_endpoint.this.id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key for vpn-ec2"
  value       = local_file.ssh_key.filename
}

output "ssh_private_key_pem" {
  description = "SSH private key PEM for vpn-ec2 (save to a .pem file, chmod 600)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

output "client_certificate_pem" {
  description = "Client certificate PEM for the .ovpn client config"
  value       = tls_locally_signed_cert.client.cert_pem
}

output "client_private_key_pem" {
  description = "Client private key PEM for the .ovpn client config"
  value       = tls_private_key.client.private_key_pem
  sensitive   = true
}
