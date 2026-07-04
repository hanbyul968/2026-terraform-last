terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}

variable "keycloak_admin_password" {
  description = "Keycloak admin 패스워드"
  type        = string
  default     = "admin1234!"
}

# ─────────────────────────────────────────────
# Default VPC (없으면 자동 생성, 있으면 채택)
# ─────────────────────────────────────────────
resource "aws_default_vpc" "default" {}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_default_subnet" "az" {
  count             = 2
  availability_zone = data.aws_availability_zones.available.names[count.index]
  depends_on        = [aws_default_vpc.default]
}

# ─────────────────────────────────────────────
# Security Group: Keycloak EC2
# ─────────────────────────────────────────────
resource "aws_security_group" "keycloak" {
  name   = "gj2026-keycloak-sg"
  vpc_id = aws_default_vpc.default.id

  # 전체 개방 (연습 편의)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "gj2026-keycloak-sg" }
}

# ─────────────────────────────────────────────
# IAM Role: EC2
# ─────────────────────────────────────────────
resource "aws_iam_role" "ec2" {
  name = "gj2026-keycloak-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_admin" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "gj2026-keycloak-ec2-profile"
  role = aws_iam_role.ec2.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────
# EC2: gj2026-keycloak-ec2
# Keycloak 26.x + HTTPS (nginx reverse proxy + self-signed cert)
# ─────────────────────────────────────────────
resource "aws_instance" "keycloak" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_default_subnet.az[0].id
  vpc_security_group_ids      = [aws_security_group.keycloak.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true

  user_data = <<-USEREOF
#!/bin/bash
# set -e 제거: 한 단계 실패가 전체 부팅 스크립트를 중단시키지 않도록

############################################
# 1) nginx + 자체서명 인증서를 가장 먼저 기동
#    → OIDC thumbprint를 빠르게 확보 (Keycloak 다운로드와 무관)
#    인증서 SAN은 thumbprint에 불필요하므로 IP 의존 제거(고정 CN)
############################################
# SSH 비밀번호 접속 허용 (채점관 SSH 대비)
echo "ec2-user:Skill53##" | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
find /etc/ssh/sshd_config.d/ -type f -exec sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' {} \;
systemctl restart sshd

dnf install -y nginx openssl jq

# Public IP (IMDSv2) — 인증서 SAN 에 포함해야 STS OIDC 의 TLS 검증 통과 (최신 TLS 클라이언트는 CN 무시, SAN 필수)
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PUBIP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl.key \
  -out /etc/nginx/ssl.crt \
  -subj "/CN=$PUBIP/O=GJ2026" \
  -addext "subjectAltName=IP:$PUBIP,DNS:keycloak"

cat > /etc/nginx/conf.d/keycloak.conf << 'NGINXEOF'
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl.crt;
    ssl_certificate_key /etc/nginx/ssl.key;

    location / {
        proxy_pass         http://localhost:8080;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
    }
}
NGINXEOF

systemctl enable nginx
systemctl restart nginx

############################################
# 2) Java + Keycloak 설치/기동
############################################
dnf install -y java-21-amazon-corretto

KEYCLOAK_VERSION="26.0.0"
cd /opt
# AL2023엔 wget이 없으므로 curl 사용 (github redirect → -L)
curl -fsSLO "https://github.com/keycloak/keycloak/releases/download/$KEYCLOAK_VERSION/keycloak-$KEYCLOAK_VERSION.tar.gz"
tar -xzf "keycloak-$KEYCLOAK_VERSION.tar.gz"
ln -s "keycloak-$KEYCLOAK_VERSION" keycloak
rm "keycloak-$KEYCLOAK_VERSION.tar.gz"
useradd -r -s /sbin/nologin keycloak || true
chown -R keycloak:keycloak /opt/keycloak*

cat > /opt/keycloak/conf/keycloak.conf << 'KCEOF'
http-enabled=true
http-port=8080
hostname-strict=false
proxy-headers=xforwarded
KCEOF

cat > /etc/systemd/system/keycloak.service << 'SVCEOF'
[Unit]
Description=Keycloak
After=network.target

[Service]
Type=simple
User=keycloak
Environment=KEYCLOAK_ADMIN=admin
Environment=KEYCLOAK_ADMIN_PASSWORD=${var.keycloak_admin_password}
ExecStart=/opt/keycloak/bin/kc.sh start-dev
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable keycloak
systemctl start keycloak

# Keycloak 준비 대기 후 Realm/Users/Clients 구성 스크립트
cat > /usr/local/bin/keycloak-setup.sh << 'SETUPEOF'
#!/bin/bash
set -e

KEYCLOAK_URL="http://localhost:8080"
ADMIN_PW="${var.keycloak_admin_password}"

# 준비 대기
for i in $(seq 1 60); do
  if curl -sf "$KEYCLOAK_URL/realms/master" > /dev/null 2>&1; then
    echo "Keycloak 준비 완료"
    break
  fi
  echo "대기 중... ($i/60)"
  sleep 5
done

# Admin 토큰
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=$ADMIN_PW" -d "grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

H="Authorization: Bearer $TOKEN"
B="$KEYCLOAK_URL/admin/realms"

# Realm: team 생성
curl -sf -X POST "$B" -H "$H" -H "Content-Type: application/json" -d '{"realm":"team","enabled":true}' || true

# Groups: dev-team, sec-team
for g in dev-team sec-team; do
  curl -sf -X POST "$B/team/groups" -H "$H" -H "Content-Type: application/json" -d "{\"name\":\"$g\"}" || true
done

DEV_GROUP_ID=$(curl -sf "$B/team/groups" -H "$H" | python3 -c "import sys,json; [print(g['id']) for g in json.load(sys.stdin) if g['name']=='dev-team']")
SEC_GROUP_ID=$(curl -sf "$B/team/groups" -H "$H" | python3 -c "import sys,json; [print(g['id']) for g in json.load(sys.stdin) if g['name']=='sec-team']")

# Client Scope: gj2026-keycloak-claims
SCOPE_PAYLOAD='{
  "name": "gj2026-keycloak-claims",
  "protocol": "openid-connect",
  "attributes": {"include.in.token.scope": "true"}
}'
curl -sf -X POST "$B/team/client-scopes" -H "$H" -H "Content-Type: application/json" -d "$SCOPE_PAYLOAD" || true
SCOPE_ID=$(curl -sf "$B/team/client-scopes" -H "$H" | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin) if s['name']=='gj2026-keycloak-claims']")

# Mappers: role, team, group → ID Token
for MAPPER_NAME in role team group; do
  CLAIM_NAME=$MAPPER_NAME
  USER_ATTR=$MAPPER_NAME
  if [ "$MAPPER_NAME" = "group" ]; then
    MAPPER_PAYLOAD="{\"name\":\"group\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-group-membership-mapper\",\"config\":{\"full.path\":\"false\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"group\",\"userinfo.token.claim\":\"true\"}}"
  else
    MAPPER_PAYLOAD="{\"name\":\"$MAPPER_NAME\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-attribute-mapper\",\"config\":{\"user.attribute\":\"$USER_ATTR\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"$CLAIM_NAME\",\"userinfo.token.claim\":\"true\"}}"
  fi
  curl -sf -X POST "$B/team/client-scopes/$SCOPE_ID/protocol-mappers/models" \
    -H "$H" -H "Content-Type: application/json" -d "$MAPPER_PAYLOAD" || true
done

# Clients: gj2026-keycloak-dev, gj2026-keycloak-sec
for CLIENT in gj2026-keycloak-dev gj2026-keycloak-sec; do
  CLIENT_PAYLOAD="{
    \"clientId\": \"$CLIENT\",
    \"enabled\": true,
    \"publicClient\": true,
    \"protocol\": \"openid-connect\",
    \"standardFlowEnabled\": false,
    \"directAccessGrantsEnabled\": true,
    \"defaultClientScopes\": [\"gj2026-keycloak-claims\"]
  }"
  curl -sf -X POST "$B/team/clients" -H "$H" -H "Content-Type: application/json" -d "$CLIENT_PAYLOAD" || true
done

# Users: dev-user (dev-team), sec-user (sec-team)
create_user() {
  local USERNAME=$1 PASSWORD=$2 GROUP_ID=$3 TEAM=$4
  USER_PAYLOAD="{
    \"username\": \"$USERNAME\",
    \"enabled\": true,
    \"emailVerified\": true,
    \"email\": \"$USERNAME@example.com\",
    \"firstName\": \"$USERNAME\",
    \"lastName\": \"user\",
    \"requiredActions\": [],
    \"credentials\": [{\"type\":\"password\",\"value\":\"$PASSWORD\",\"temporary\":false}],
    \"attributes\": {\"team\":[\"$TEAM\"]}
  }"
  curl -sf -X POST "$B/team/users" -H "$H" -H "Content-Type: application/json" -d "$USER_PAYLOAD" || true
  USER_ID=$(curl -sf "$B/team/users?username=$USERNAME" -H "$H" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  curl -sf -X PUT "$B/team/users/$USER_ID/groups/$GROUP_ID" -H "$H" || true
}

create_user "dev-user" "dev123!" "$DEV_GROUP_ID" "dev-team"
create_user "sec-user" "sec123!" "$SEC_GROUP_ID" "sec-team"

echo "Keycloak 초기 설정 완료"
SETUPEOF

chmod +x /usr/local/bin/keycloak-setup.sh

# 백그라운드에서 설정 스크립트 실행
nohup /usr/local/bin/keycloak-setup.sh > /var/log/keycloak-setup.log 2>&1 &

############################################
# 3) AWS CLI 인증 스크립트 (~/.aws/gj2026-keycloak-creds.sh) 자동 생성 (채점 4-3)
#    Keycloak ROPC(비밀번호 그랜트) → ID Token → STS AssumeRoleWithWebIdentity
#    → credential_process 형식 JSON 출력.
#    사용: gj2026-keycloak-creds.sh <dev|sec> <username>
#    - Role Session Name: keycloak-session
#    - team→role/client/password 매핑 (dev-user/dev-user2 = dev123!, sec-user = sec123!)
############################################
mkdir -p /home/ec2-user/.aws
cat > /home/ec2-user/.aws/gj2026-keycloak-creds.sh << 'CREDSEOF'
#!/bin/bash
set -euo pipefail
TEAM="$${1:?team(dev|sec) required}"
USERNAME="$${2:?username required}"
REGION="eu-central-1"
ACCT="__ACCOUNT_ID__"

case "$TEAM" in
  dev) CLIENT="gj2026-keycloak-dev"; ROLE="gj2026-keycloak-dev-role"; PW="dev123!" ;;
  sec) CLIENT="gj2026-keycloak-sec"; ROLE="gj2026-keycloak-sec-role"; PW="sec123!" ;;
  *) echo "unknown team: $TEAM" >&2; exit 1 ;;
esac

# Keycloak EC2 Public IP (태그로 조회 → CloudShell/EC2 어디서든 동작; IMDS 의존 제거)
IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Keycloak 비밀번호 그랜트로 ID Token 발급 (public client)
ID_TOKEN=$(curl -sk -X POST "https://$IP/realms/team/protocol/openid-connect/token" \
  -d "client_id=$CLIENT" -d "username=$USERNAME" -d "password=$PW" \
  -d "grant_type=password" -d "scope=openid" | jq -r '.id_token')

# STS 임시 자격증명 (web identity)
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::$ACCT:role/$ROLE" \
  --role-session-name keycloak-session \
  --web-identity-token "$ID_TOKEN" \
  --query 'Credentials' --output json)

# credential_process 규격 출력
echo "$CREDS" | jq '{Version:1, AccessKeyId:.AccessKeyId, SecretAccessKey:.SecretAccessKey, SessionToken:.SessionToken, Expiration:.Expiration}'
CREDSEOF

# 생성 시점 계정 ID 주입 (credential_process 재귀 방지: sts 호출 없이 ARN 구성)
sed -i "s/__ACCOUNT_ID__/${data.aws_caller_identity.current.account_id}/" \
  /home/ec2-user/.aws/gj2026-keycloak-creds.sh
chmod +x /home/ec2-user/.aws/gj2026-keycloak-creds.sh
chown -R ec2-user:ec2-user /home/ec2-user/.aws

# gj2026-keycloak-dev / gj2026-keycloak-sec 프로파일 등록 (credential_process)
sudo -u ec2-user aws configure set credential_process \
  "/home/ec2-user/.aws/gj2026-keycloak-creds.sh dev dev-user" --profile gj2026-keycloak-dev || true
sudo -u ec2-user aws configure set credential_process \
  "/home/ec2-user/.aws/gj2026-keycloak-creds.sh sec sec-user" --profile gj2026-keycloak-sec || true
USEREOF

  tags = { Name = "gj2026-keycloak-ec2" }
}

# ─────────────────────────────────────────────
# IAM: OIDC Provider 등록 (EC2 Public IP 필요 → null_resource)
# ─────────────────────────────────────────────
resource "null_resource" "oidc_provider" {
  depends_on = [aws_instance.keycloak]

  triggers = {
    instance_id = aws_instance.keycloak.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "bash '${path.module}/oidc.sh' '${aws_instance.keycloak.id}' 'eu-central-1'"
  }
}

# ─────────────────────────────────────────────
# IAM Policy: dev-team (team=dev-team 태그 EC2만 start/stop)
# ─────────────────────────────────────────────
resource "aws_iam_policy" "dev" {
  name        = "gj2026-keycloak-dev-policy"
  description = "dev-team: team=dev-team 태그 EC2 start/stop"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/team" = "dev-team"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Deny"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "ec2:ResourceTag/team" = "dev-team"
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────
# IAM Policy: sec-team (team=sec-team 태그 EC2만 start/stop)
# ─────────────────────────────────────────────
resource "aws_iam_policy" "sec" {
  name        = "gj2026-keycloak-sec-policy"
  description = "sec-team: team=sec-team 태그 EC2 start/stop"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/team" = "sec-team"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Deny"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "ec2:ResourceTag/team" = "sec-team"
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────
# IAM Role: gj2026-keycloak-dev-role
# (OIDC Provider ARN은 null_resource 이후 생성되므로 local-exec로 처리)
# ─────────────────────────────────────────────
resource "null_resource" "iam_roles" {
  depends_on = [null_resource.oidc_provider]

  triggers = {
    instance_id = aws_instance.keycloak.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "bash '${path.module}/iam-roles.sh' '${aws_instance.keycloak.id}' 'eu-central-1' '${aws_iam_policy.dev.arn}' '${aws_iam_policy.sec.arn}'"
  }
}

output "keycloak_public_ip" {
  value       = aws_instance.keycloak.public_ip
  description = "Keycloak EC2 공개 IP - OIDC Provider URL: https://<IP>/realms/team"
}

output "keycloak_https_url" {
  value = "https://${aws_instance.keycloak.public_ip}/realms/team"
}
