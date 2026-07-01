# ═══════════════════════════════════════════════════════════════
# VPC Endpoints  (root 소유)
#
# 진짜 VPC / 서브넷 / IGW / NAT / 라우팅은 1단계(bastion 스테이지, bastion/network.tf)로
# 이동했다. 여기서는 그것들을 data.tf 로 조회해 VPC Endpoint 만 생성한다.
#
# 채점(1-1) 라우팅 규칙:
#   - Gateway Endpoint(S3/DynamoDB)는 private RTB 에만 연결한다.
#     (workload RTB 에 붙이면 vpce 경로가 생겨 채점 0 이 깨짐)
#   - workload 서브넷의 노드는 Interface Endpoint 로만 AWS 와 통신.
# ═══════════════════════════════════════════════════════════════

# Gateway Endpoint: private RTB 에만 연결 (workload 라우팅 0 유지)
resource "aws_vpc_endpoint" "s3_gw" {
  vpc_id            = data.aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private_a.id, data.aws_route_table.private_c.id]
  tags              = { Name = "wsc-s3-gw-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb_gw" {
  vpc_id            = data.aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private_a.id, data.aws_route_table.private_c.id]
  tags              = { Name = "wsc-dynamodb-gw-endpoint" }
}

# Interface Endpoint 보안그룹: VPC 내부에서 443 허용
resource "aws_security_group" "vpce" {
  name        = "wsc-vpce-sg"
  description = "VPC Interface Endpoint SG"
  vpc_id      = data.aws_vpc.this.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-vpce-sg" }
}

locals {
  # workload 노드가 AWS 서비스에 닿기 위한 Interface Endpoint 목록.
  # 인터넷/NAT 가 없으므로 노드가 쓰는 서비스는 전부 여기에 있어야 한다.
  interface_endpoints = [
    "ecr.api", "ecr.dkr", "sts", "logs", "ec2",
    "eks", "eks-auth", "elasticloadbalancing", "autoscaling",
    "ssm", "ssmmessages", "ec2messages", "monitoring",
    "s3", # ECR 레이어(S3) 를 라우팅 없이 받기 위한 Interface 형 S3
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [data.aws_subnet.workload_a.id, data.aws_subnet.workload_c.id]
  security_group_ids  = [aws_security_group.vpce.id]
  tags                = { Name = "wsc-${replace(each.key, ".", "-")}-endpoint" }
}


# ── DynamoDB Interface Endpoint ──
# DynamoDB 인터페이스 엔드포인트는 private DNS 를 지원하지 않으므로(표준 dynamodb.<region>.amazonaws.com
# 이 이 엔드포인트로 안 감), book 파드(workload 서브넷, 라우팅 0)가 DynamoDB 에 닿으려면
# 이 엔드포인트의 DNS 를 앱 SDK 에 AWS_ENDPOINT_URL_DYNAMODB 로 지정한다(k8s ConfigMap).
# gateway endpoint 를 workload RTB 에 붙이면 vpce- 경로가 생겨 채점 1-3-A(라우팅 0) 위반이므로 불가.
resource "aws_vpc_endpoint" "dynamodb_interface" {
  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = false
  subnet_ids          = [data.aws_subnet.workload_a.id, data.aws_subnet.workload_c.id]
  security_group_ids  = [aws_security_group.vpce.id]
  tags                = { Name = "wsc-dynamodb-interface-endpoint" }
}

output "dynamodb_endpoint_dns" {
  description = "book 파드가 AWS_ENDPOINT_URL_DYNAMODB 로 쓸 DynamoDB 인터페이스 엔드포인트 DNS"
  value       = "https://${tolist(aws_vpc_endpoint.dynamodb_interface.dns_entry)[0].dns_name}"
}
