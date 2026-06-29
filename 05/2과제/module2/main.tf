terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "gj2026-data"
  # 배포파일 app.py (채점 2-2 SHA256 검증 → 바이트 그대로 배치)
  app_py_b64 = filebase64("${path.module}/../files/data-app.py")
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
# Security Group: EC2 (Kafka)
# ─────────────────────────────────────────────
resource "aws_security_group" "kafka" {
  name   = "${local.name}-kafka-sg"
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

  tags = { Name = "${local.name}-kafka-sg" }
}

# ─────────────────────────────────────────────
# IAM Role: EC2
# ─────────────────────────────────────────────
resource "aws_iam_role" "ec2" {
  name = "${local.name}-ec2-role"
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

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2-profile"
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
# EC2: gj2026-data-ec2 (Kafka KRaft + App)
# ─────────────────────────────────────────────
resource "aws_instance" "kafka" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_default_subnet.az[0].id
  vpc_security_group_ids      = [aws_security_group.kafka.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true # userdata 바뀌면 인스턴스 교체(새 userdata 실행 보장)

  user_data = <<-EOF
#!/bin/bash
# 진단용 로그 + set -e 제거(한 단계 실패가 전체 중단되지 않게)
exec > /var/log/userdata.log 2>&1
set -x

# SSH 비밀번호 접속 허용 (채점관 SSH 대비)
echo "ec2-user:Skill53##" | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
find /etc/ssh/sshd_config.d/ -type f -exec sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' {} \;
systemctl restart sshd

# 배포 app.py + 로그 디렉터리 먼저 배치 (느린 설치와 무관하게 항상 존재)
echo "${local.app_py_b64}" | base64 -d > /home/ec2-user/app.py
chown ec2-user:ec2-user /home/ec2-user/app.py
mkdir -p /var/log/app
chown -R ec2-user:ec2-user /var/log/app

# Java + pip + Kafka 클라이언트
dnf install -y java-21-amazon-corretto python3-pip
pip3 install kafka-python

# Kafka 4.x 다운로드 (dlcdn: 빠름, 실패 시 archive 폴백)
KAFKA_VERSION="4.0.1"
SCALA_VERSION="2.13"
KT="kafka_$${SCALA_VERSION}-$${KAFKA_VERSION}.tgz"
cd /opt
curl -fsSL --retry 3 -o "$KT" "https://dlcdn.apache.org/kafka/$${KAFKA_VERSION}/$KT" \
  || curl -fsSL --retry 3 -o "$KT" "https://archive.apache.org/dist/kafka/$${KAFKA_VERSION}/$KT"
tar -xzf "$KT"
ln -s "kafka_$${SCALA_VERSION}-$${KAFKA_VERSION}" kafka
rm "$KT"

# KRaft 모드 설정 (4.x는 config/kraft 디렉터리 없음 → config/server.properties)
CLUSTER_ID=$(/opt/kafka/bin/kafka-storage.sh random-uuid)
# 외부 advertised는 NLB DNS 사용 (Flink가 NLB:9094로 접속) - IMDS 불필요
cat > /opt/kafka/config/server.properties << KAFKAEOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093
listeners=INTERNAL://0.0.0.0:9092,EXTERNAL://0.0.0.0:9094,CONTROLLER://0.0.0.0:9093
advertised.listeners=INTERNAL://localhost:9092,EXTERNAL://${aws_lb.data.dns_name}:9094
listener.security.protocol.map=INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=INTERNAL
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/logs
num.partitions=1
auto.create.topics.enable=false
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
KAFKAEOF

# 데이터 디렉터리 초기화
mkdir -p /var/lib/kafka/logs
/opt/kafka/bin/kafka-storage.sh format -t "$CLUSTER_ID" -c /opt/kafka/config/server.properties

# systemd 서비스 등록
cat > /etc/systemd/system/kafka.service << SVCEOF
[Unit]
Description=Apache Kafka (KRaft)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable kafka
systemctl start kafka

# Kafka 준비 대기
sleep 30

# 토픽 생성
/opt/kafka/bin/kafka-topics.sh --create --topic order-logs   --partitions 2 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic error-stats  --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic high-latency --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-topics.sh --create --topic anomaly      --partitions 1 --replication-factor 1 --bootstrap-server localhost:9092

# 앱 로그 디렉터리 (app.py가 ec2-user로 실행되어 기록)
mkdir -p /var/log/app
chown -R ec2-user:ec2-user /var/log/app
EOF

  tags = { Name = "gj2026-data-ec2" }
}

# ─────────────────────────────────────────────
# NLB: gj2026-data-nlb (Internet-facing, TCP:9094)
# ─────────────────────────────────────────────
resource "aws_lb" "data" {
  name               = "gj2026-data-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_default_subnet.az[*].id

  tags = { Name = "gj2026-data-nlb" }
}

resource "aws_lb_target_group" "kafka" {
  name        = "${local.name}-kafka-tg"
  port        = 9094
  protocol    = "TCP"
  vpc_id      = aws_default_vpc.default.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "9094"
  }
}

resource "aws_lb_target_group_attachment" "kafka" {
  target_group_arn = aws_lb_target_group.kafka.arn
  target_id        = aws_instance.kafka.id
  port             = 9094
}

resource "aws_lb_listener" "kafka" {
  load_balancer_arn = aws_lb.data.arn
  port              = 9094
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kafka.arn
  }
}

# ─────────────────────────────────────────────
# Glue Database: real_time_analytics
# ─────────────────────────────────────────────
resource "aws_glue_catalog_database" "analytics" {
  name = "real_time_analytics"
}

# ─────────────────────────────────────────────
# IAM Role: Managed Apache Flink (Zeppelin)
# ─────────────────────────────────────────────
resource "aws_iam_role" "flink" {
  name = "${local.name}-flink-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "kinesisanalytics.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flink" {
  name = "${local.name}-flink-policy"
  role = aws_iam_role.flink.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["glue:*"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream",
          "logs:PutLogEvents", "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Managed Apache Flink: Zeppelin Studio Notebook
# (Terraform aws provider가 Zeppelin Studio 미지원 → AWS CLI로 생성)
# Glue Database를 메타스토어로 연결. 3개 쿼리는 노트북에서 수동 작성.
# ─────────────────────────────────────────────
resource "null_resource" "zeppelin" {
  triggers = {
    region = data.aws_region.current.name
    name   = "${local.name}-zeppelin"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "bash '${path.module}/zeppelin.sh' '${data.aws_region.current.name}' '${aws_iam_role.flink.arn}' '${data.aws_caller_identity.current.account_id}' '${local.name}-zeppelin'"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "bash '${path.module}/zeppelin-delete.sh' '${self.triggers.region}' '${self.triggers.name}'"
  }

  depends_on = [aws_iam_role_policy.flink, aws_glue_catalog_database.analytics]
}

output "kafka_ec2_public_ip" {
  value = aws_instance.kafka.public_ip
}

output "nlb_dns" {
  value = aws_lb.data.dns_name
}

output "zeppelin_app_name" {
  value = "${local.name}-zeppelin"
}
