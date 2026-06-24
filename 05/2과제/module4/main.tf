terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
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
    values = ["al2023-ami-*-x86_64"]
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
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_default_subnet.az[0].id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = <<-USEREOF
#!/bin/bash
# set -e 제거: 한 단계 실패가 전체 부팅 스크립트를 중단시키지 않도록

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

############################################
# 1) nginx + 자체서명 인증서를 가장 먼저 기동
#    → OIDC thumbprint를 빠르게 확보 (Keycloak 다운로드와 무관)
############################################
dnf install -y nginx openssl

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl.key \
  -out /etc/nginx/ssl.crt \
  -subj "/CN=$PUBLIC_IP/O=GJ2026" \
  -addext "subjectAltName=IP:$PUBLIC_IP"

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
wget -q "https://github.com/keycloak/keycloak/releases/download/$KEYCLOAK_VERSION/keycloak-$KEYCLOAK_VERSION.tar.gz"
tar -xzf "keycloak-$KEYCLOAK_VERSION.tar.gz"
ln -s "keycloak-$KEYCLOAK_VERSION" keycloak
rm "keycloak-$KEYCLOAK_VERSION.tar.gz"
useradd -r -s /sbin/nologin keycloak || true
chown -R keycloak:keycloak /opt/keycloak*

cat > /opt/keycloak/conf/keycloak.conf << 'KCEOF'
http-enabled=true
http-port=8080
hostname-strict=false
proxy=edge
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
    \"publicClient\": false,
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
    interpreter = ["bash", "-c"]
    command     = <<-SCRIPT
      set -e

      IP=$(aws ec2 describe-instances \
        --instance-ids ${aws_instance.keycloak.id} \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text --region eu-central-1)
      echo "Keycloak IP: $IP"

      # HTTPS(nginx) + Keycloak realm 준비될 때까지 대기 (최대 ~10분)
      echo "Keycloak HTTPS 준비 대기..."
      for i in $(seq 1 60); do
        THUMBPRINT=$(echo | openssl s_client -connect "$IP:443" -servername "$IP" -showcerts 2>/dev/null \
          | openssl x509 -fingerprint -noout -sha1 2>/dev/null \
          | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
        if [ -n "$THUMBPRINT" ]; then
          echo "Thumbprint 획득: $THUMBPRINT (시도 $i)"
          break
        fi
        echo "  대기 중... ($i/60)"
        sleep 10
      done

      if [ -z "$THUMBPRINT" ]; then
        echo "ERROR: HTTPS 인증서를 가져오지 못했습니다. EC2 부팅/nginx 상태를 확인하세요."
        exit 1
      fi

      EXISTING=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text | grep "$IP/realms/team" || true)
      if [ -z "$EXISTING" ]; then
        aws iam create-open-id-connect-provider \
          --url "https://$IP/realms/team" \
          --client-id-list gj2026-keycloak-dev gj2026-keycloak-sec \
          --thumbprint-list "$THUMBPRINT"
        echo "OIDC Provider 생성 완료"
      else
        echo "OIDC Provider 이미 존재: $EXISTING"
      fi
    SCRIPT
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
    interpreter = ["bash", "-c"]
    command     = <<-SCRIPT
      set -e

      IP=$(aws ec2 describe-instances \
        --instance-ids ${aws_instance.keycloak.id} \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text --region eu-central-1)

      ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      OIDC_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$IP/realms/team"
      OIDC_URL="$IP/realms/team"

      DEV_POLICY_ARN="${aws_iam_policy.dev.arn}"
      SEC_POLICY_ARN="${aws_iam_policy.sec.arn}"

      create_role() {
        local ROLE_NAME=$1 CLIENT=$2 TEAM=$3 POLICY_ARN=$4
        local TRUST="{
          \"Version\": \"2012-10-17\",
          \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Principal\": {\"Federated\": \"$OIDC_ARN\"},
            \"Action\": \"sts:AssumeRoleWithWebIdentity\",
            \"Condition\": {
              \"StringEquals\": {\"$OIDC_URL:aud\": \"$CLIENT\"}
            }
          }]
        }"
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" 2>/dev/null || \
          aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
      }

      create_role "gj2026-keycloak-dev-role" "gj2026-keycloak-dev" "dev-team" "$DEV_POLICY_ARN"
      create_role "gj2026-keycloak-sec-role" "gj2026-keycloak-sec" "sec-team" "$SEC_POLICY_ARN"

      echo "IAM 역할 생성 완료"
    SCRIPT
  }
}

output "keycloak_public_ip" {
  value       = aws_instance.keycloak.public_ip
  description = "Keycloak EC2 공개 IP - OIDC Provider URL: https://<IP>/realms/team"
}

output "keycloak_https_url" {
  value = "https://${aws_instance.keycloak.public_ip}/realms/team"
}
