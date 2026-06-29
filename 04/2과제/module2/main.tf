terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 4-2 VPC Lattice — ap-southeast-1
provider "aws" {
  region = "ap-southeast-1"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Hub VPC (10.0.0.0/16) ────────────────────────────────────────────
resource "aws_vpc" "hub" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc-hub-vpc" }
}
resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "wsc-hub-igw" }
}
resource "aws_subnet" "hub_pub_a" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc-hub-sn-pub-a" }
}
resource "aws_subnet" "hub_pub_c" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-southeast-1c"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc-hub-sn-pub-c" }
}
resource "aws_route_table" "hub_pub" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }
  tags = { Name = "wsc-hub-pub-rtb" }
}
resource "aws_route_table_association" "hub_pub_a" {
  subnet_id      = aws_subnet.hub_pub_a.id
  route_table_id = aws_route_table.hub_pub.id
}
resource "aws_route_table_association" "hub_pub_c" {
  subnet_id      = aws_subnet.hub_pub_c.id
  route_table_id = aws_route_table.hub_pub.id
}

# ── Spoke VPC (192.168.0.0/16) ───────────────────────────────────────
resource "aws_vpc" "spoke" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc-spoke-vpc" }
}
resource "aws_internet_gateway" "spoke" {
  vpc_id = aws_vpc.spoke.id
  tags   = { Name = "wsc-spoke-igw" }
}
resource "aws_subnet" "spoke_pub_a" {
  vpc_id                  = aws_vpc.spoke.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc-spoke-sn-pub-a" }
}
resource "aws_subnet" "spoke_pub_c" {
  vpc_id                  = aws_vpc.spoke.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "ap-southeast-1c"
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc-spoke-sn-pub-c" }
}
resource "aws_subnet" "spoke_priv_a" {
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = "192.168.2.0/24"
  availability_zone = "ap-southeast-1a"
  tags              = { Name = "wsc-spoke-sn-priv-a" }
}
resource "aws_subnet" "spoke_priv_c" {
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = "192.168.3.0/24"
  availability_zone = "ap-southeast-1c"
  tags              = { Name = "wsc-spoke-sn-priv-c" }
}
resource "aws_eip" "spoke_nat" { domain = "vpc" }
resource "aws_nat_gateway" "spoke" {
  allocation_id = aws_eip.spoke_nat.id
  subnet_id     = aws_subnet.spoke_pub_a.id
  tags          = { Name = "wsc-spoke-nat" }
  depends_on    = [aws_internet_gateway.spoke]
}
resource "aws_route_table" "spoke_pub" {
  vpc_id = aws_vpc.spoke.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.spoke.id
  }
  tags = { Name = "wsc-spoke-pub-rtb" }
}
resource "aws_route_table" "spoke_priv" {
  vpc_id = aws_vpc.spoke.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.spoke.id
  }
  tags = { Name = "wsc-spoke-priv-rtb" }
}
resource "aws_route_table_association" "spoke_pub_a" {
  subnet_id      = aws_subnet.spoke_pub_a.id
  route_table_id = aws_route_table.spoke_pub.id
}
resource "aws_route_table_association" "spoke_pub_c" {
  subnet_id      = aws_subnet.spoke_pub_c.id
  route_table_id = aws_route_table.spoke_pub.id
}
resource "aws_route_table_association" "spoke_priv_a" {
  subnet_id      = aws_subnet.spoke_priv_a.id
  route_table_id = aws_route_table.spoke_priv.id
}
resource "aws_route_table_association" "spoke_priv_c" {
  subnet_id      = aws_subnet.spoke_priv_c.id
  route_table_id = aws_route_table.spoke_priv.id
}

# ── Hub Bastion (SSH pw Skill53##, EIP) ──────────────────────────────
resource "aws_security_group" "hub_bastion" {
  name   = "wsc-hub-bastion-sg"
  vpc_id = aws_vpc.hub.id
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
  tags = { Name = "wsc-hub-bastion-sg" }
}
resource "aws_instance" "hub_bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.hub_pub_a.id
  vpc_security_group_ids      = [aws_security_group.hub_bastion.id]
  associate_public_ip_address = true
  user_data                   = <<-EOF
    #!/bin/bash
    echo 'ec2-user:Skill53##' | chpasswd
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd
  EOF
  tags                        = { Name = "wsc-hub-bastion" }
}
resource "aws_eip" "hub_bastion" {
  instance = aws_instance.hub_bastion.id
  domain   = "vpc"
  tags     = { Name = "wsc-hub-bastion-eip" }
}

# ── App EC2 v1/v2 (Spoke private-a, TCP8080) ─────────────────────────
resource "aws_security_group" "app" {
  name   = "wsc-spoke-app-sg"
  vpc_id = aws_vpc.spoke.id
  ingress {
    description = "app 8080 from spoke"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-spoke-app-sg" }
}

# 배포파일 version1.py / version2.py 를 app/ 에 두고 그대로 실행 (수정 금지).
# 아래 user_data 는 app/<file> 를 EC2 로 전달해 python3 로 기동한다.
locals {
  app_v1 = fileexists("${path.module}/app/version1.py") ? file("${path.module}/app/version1.py") : "from http.server import BaseHTTPRequestHandler,HTTPServer\nimport json\nclass H(BaseHTTPRequestHandler):\n  def do_GET(self):\n    b=json.dumps({'version':'v1'}) if self.path=='/version' else (json.dumps({'status':'ok'}) if self.path=='/healthcheck' else '')\n    self.send_response(200 if b else 404);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b.encode())\nHTTPServer(('0.0.0.0',8080),H).serve_forever()\n"
  app_v2 = fileexists("${path.module}/app/version2.py") ? file("${path.module}/app/version2.py") : "from http.server import BaseHTTPRequestHandler,HTTPServer\nimport json\nclass H(BaseHTTPRequestHandler):\n  def do_GET(self):\n    b=json.dumps({'version':'v2'}) if self.path=='/version' else (json.dumps({'status':'ok'}) if self.path=='/healthcheck' else '')\n    self.send_response(200 if b else 404);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b.encode())\nHTTPServer(('0.0.0.0',8080),H).serve_forever()\n"
}

resource "aws_instance" "app_v1" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.spoke_priv_a.id
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = <<-EOF
    #!/bin/bash
    set -eux
    cat > /opt/app.py <<'PY'
    ${local.app_v1}
    PY
    nohup python3 /opt/app.py >/var/log/app.log 2>&1 &
  EOF
  tags                   = { Name = "wsc-spoke-app-v1" }
}
resource "aws_instance" "app_v2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.spoke_priv_a.id
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = <<-EOF
    #!/bin/bash
    set -eux
    cat > /opt/app.py <<'PY'
    ${local.app_v2}
    PY
    nohup python3 /opt/app.py >/var/log/app.log 2>&1 &
  EOF
  tags                   = { Name = "wsc-spoke-app-v2" }
}

# ── Internal ALB (Spoke private) + TGs ───────────────────────────────
resource "aws_security_group" "alb" {
  name   = "wsc-spoke-alb-sg"
  vpc_id = aws_vpc.spoke.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16", "192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-spoke-alb-sg" }
}

resource "aws_lb" "app" {
  name               = "wsc-spoke-app-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.spoke_priv_a.id, aws_subnet.spoke_priv_c.id]
  tags               = { Name = "wsc-spoke-app-alb" }
}

resource "aws_lb_target_group" "v1" {
  name        = "wsc-spoke-v1-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.spoke.id
  target_type = "instance"
  health_check {
    path     = "/version"
    protocol = "HTTP"
    matcher  = "200"
  }
}
resource "aws_lb_target_group" "v2" {
  name        = "wsc-spoke-v2-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.spoke.id
  target_type = "instance"
  health_check {
    path     = "/version"
    protocol = "HTTP"
    matcher  = "200"
  }
}
resource "aws_lb_target_group_attachment" "v1" {
  target_group_arn = aws_lb_target_group.v1.arn
  target_id        = aws_instance.app_v1.id
  port             = 8080
}
resource "aws_lb_target_group_attachment" "v2" {
  target_group_arn = aws_lb_target_group.v2.arn
  target_id        = aws_instance.app_v2.id
  port             = 8080
}

# default 80 listener: weighted v1 90% / v2 10%
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.v1.arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.v2.arn
        weight = 10
      }
    }
  }
}

# /healthcheck -> 403 "Restrict access to api"
resource "aws_lb_listener_rule" "healthcheck_block" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 5
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Restrict access to api"
      status_code  = "403"
    }
  }
  condition {
    path_pattern { values = ["/healthcheck"] }
  }
}

# non-API -> 404 "Not Found" (only /version allowed through to weighted default)
resource "aws_lb_listener_rule" "version_ok" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.v1.arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.v2.arn
        weight = 10
      }
    }
  }
  condition {
    path_pattern { values = ["/version"] }
  }
}
resource "aws_lb_listener_rule" "not_found" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
  condition {
    path_pattern { values = ["/*"] }
  }
}

# ── VPC Lattice (Hub -> Spoke ALB, header + weighted routing) ────────
resource "aws_vpclattice_service_network" "main" {
  name      = "wsc-app-service-network"
  auth_type = "NONE"
}
resource "aws_vpclattice_service_network_vpc_association" "hub" {
  service_network_identifier = aws_vpclattice_service_network.main.id
  vpc_identifier             = aws_vpc.hub.id
}
resource "aws_vpclattice_service" "app" {
  name      = "wsc-app-service"
  auth_type = "NONE"
}
resource "aws_vpclattice_service_network_service_association" "app" {
  service_identifier         = aws_vpclattice_service.app.id
  service_network_identifier = aws_vpclattice_service_network.main.id
}

# Lattice target groups (type ALB) -> point to the spoke ALB
resource "aws_vpclattice_target_group" "v1" {
  name = "wsc-spoke-v1-tg"
  type = "ALB"
  config {
    port           = 80
    protocol       = "HTTP"
    vpc_identifier = aws_vpc.spoke.id
  }
}
resource "aws_vpclattice_target_group" "v2" {
  name = "wsc-spoke-v2-tg"
  type = "ALB"
  config {
    port           = 80
    protocol       = "HTTP"
    vpc_identifier = aws_vpc.spoke.id
  }
}
resource "aws_vpclattice_target_group_attachment" "v1" {
  target_group_identifier = aws_vpclattice_target_group.v1.id
  target {
    id   = aws_lb.app.arn
    port = 80
  }
}
resource "aws_vpclattice_target_group_attachment" "v2" {
  target_group_identifier = aws_vpclattice_target_group.v2.id
  target {
    id   = aws_lb.app.arn
    port = 80
  }
}

resource "aws_vpclattice_listener" "http" {
  name               = "http"
  service_identifier = aws_vpclattice_service.app.id
  protocol           = "HTTP"
  port               = 80
  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.v1.id
        weight                  = 90
      }
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.v2.id
        weight                  = 10
      }
    }
  }
}

# header version:v1 -> v1-tg (priority 10, higher precedence)
resource "aws_vpclattice_listener_rule" "v1" {
  name                = "header-v1"
  service_identifier  = aws_vpclattice_service.app.id
  listener_identifier = aws_vpclattice_listener.http.listener_id
  priority            = 10
  match {
    http_match {
      header_matches {
        name = "version"
        match { exact = "v1" }
      }
    }
  }
  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.v1.id
        weight                  = 100
      }
    }
  }
}
# header version:v2 -> v2-tg (priority 20)
resource "aws_vpclattice_listener_rule" "v2" {
  name                = "header-v2"
  service_identifier  = aws_vpclattice_service.app.id
  listener_identifier = aws_vpclattice_listener.http.listener_id
  priority            = 20
  match {
    http_match {
      header_matches {
        name = "version"
        match { exact = "v2" }
      }
    }
  }
  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.v2.id
        weight                  = 100
      }
    }
  }
}

output "lattice_service_dns" { value = aws_vpclattice_service.app.dns_entry }
output "hub_bastion_ip" { value = aws_eip.hub_bastion.public_ip }
output "spoke_alb_dns" { value = aws_lb.app.dns_name }
