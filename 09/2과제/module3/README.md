# Module 3 - MSK (ap-northeast-3)

## 실행

```bash
# apply 시 비번호를 직접 물어봄 (var.competitor_number)
terraform init
terraform apply --auto-approve
#   var.competitor_number
#     대회 비번호 (예: 01, 15). ...
#   Enter a value: 01    ← 본인 비번호 입력

# 입력 없이 바로 넘기려면:
# terraform apply -var="competitor_number=01" --auto-approve
```

## apply 후 할 일

### 1. wsc-app-ec2 접속 (Session Manager)
```bash
# EC2 ID 확인
APP_ID=$(aws ec2 describe-instances --region ap-northeast-3 \
  --filters "Name=tag:Name,Values=wsc-app-ec2" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
echo $APP_ID

# 접속
aws ssm start-session --target $APP_ID --region ap-northeast-3
```

### 2. MSK 브로커 주소 확인 (EC2 안에서)
```bash
CLUSTER_ARN=$(aws kafka list-clusters --region ap-northeast-3 \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
  --region ap-northeast-3 --query BootstrapBrokerString --output text)
echo $BOOTSTRAP
```

### 3. MSK 토픽 생성

> kafka CLI(`kafka_2.13-3.5.1`)는 user_data가 **백그라운드로** 받음 (archive.apache.org가 느려 setup을 막지 않게).
> 채점 3-4도 이 CLI(`kafka-topics.sh --list`)를 쓰므로 **반드시 있어야 함**. 받아졌는지 먼저 확인:
> ```bash
> until [ -x /home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh ]; do echo "kafka 다운로드 대기..."; sleep 10; done
> echo "kafka 준비됨"
> ```

```bash
/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create \
  --bootstrap-server $BOOTSTRAP --topic order-events --partitions 3 --replication-factor 2

/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create \
  --bootstrap-server $BOOTSTRAP --topic order-events-dlq --partitions 1 --replication-factor 2

# 확인
/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --list --bootstrap-server $BOOTSTRAP
```

### 4. Consumer 실행 (백그라운드)
```bash
# 설치 확인
ls -la /home/ec2-user/ec2_consumer.py

# 없으면 수동 다운로드
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp s3://wsc-msk-setup-${ACCOUNT_ID}/ec2_consumer.py . --region ap-northeast-3

# 백그라운드 실행 (로그는 /tmp — home은 root 소유 파일 시 Permission denied)
nohup python3 /home/ec2-user/ec2_consumer.py \
  --bootstrap-servers $BOOTSTRAP \
  --bucket wsc-msk-order-data-<비번호>-bucket >> /tmp/consumer.log 2>&1 &
echo "Consumer PID: $!"
sleep 3 && cat /tmp/consumer.log
```

### 5. Lambda ESM 활성화 확인 및 Enable
```bash
# 상태 확인
aws lambda list-event-source-mappings \
  --function-name msk-order-consumer --region ap-northeast-3 \
  --query "EventSourceMappings[0].State" --output text

# Disabled 또는 Enabling이 아니면 아래 실행
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name msk-order-consumer --region ap-northeast-3 \
  --query "EventSourceMappings[0].UUID" --output text)
aws lambda update-event-source-mapping \
  --uuid $ESM_UUID --enabled --region ap-northeast-3
```

### 6. S3/DynamoDB 데이터 채우기 (채점 전 필수 — 배포파일 producer.py 사용)

> Lambda가 DynamoDB에 저장, consumer가 S3에 저장. **채점 전 반드시 실행!**
> user_data가 `/home/ec2-user/producer.py`를 자동 설치함 (없으면 setup 버킷에서 받기).

```bash
# wsc-app-ec2 안에서 실행 — order 메시지 100건 발행
python3 /home/ec2-user/producer.py --bootstrap-servers $BOOTSTRAP --count 100 --interval 0

# 없으면 수동 다운로드 후 실행
# ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# aws s3 cp s3://wsc-msk-setup-${ACCOUNT_ID}/producer.py . --region ap-northeast-3

# 10초 후 확인 (Lambda 권한은 EC2 역할에 추가됨)
sleep 10
aws dynamodb scan --table-name order-records \
  --select COUNT --query Count --output text --region ap-northeast-3
aws s3 ls s3://wsc-msk-order-data-<비번호>-bucket/orders/ --recursive | head -5
```

## 채점 스크립트(mark2-3.sh) 변수 채우기

채점 스크립트 상단에 아래 3개 플레이스홀더가 있음 — **안 채우면 3-2(MSK 연결)·3-4(토픽 list)의 SSM 명령이 실패**함:
```
APP_ID="<App EC2 인스턴스 ID 입력 (i-xxxxxxxxx)>"
BOOTSTRAP_HOST="<MSK 부트스트랩 브로커 1개 호스트, 포트 제외>"
BOOTSTRAP="<부트스트랩 브로커 주소 (포트 포함)>"
```

### 1) 값 추출 (스크립트와 같은 셸에서 실행)
```bash
# App EC2 인스턴스 ID
APP_ID=$(aws ec2 describe-instances --region ap-northeast-3 \
  --filters "Name=tag:Name,Values=wsc-app-ec2" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

# MSK 부트스트랩 (포트 포함) + 호스트 1개(포트 제외)
CLUSTER_ARN=$(aws kafka list-clusters --region ap-northeast-3 \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
  --region ap-northeast-3 --query BootstrapBrokerString --output text)
BOOTSTRAP_HOST=$(echo $BOOTSTRAP | cut -d',' -f1 | cut -d':' -f1)

echo "APP_ID=$APP_ID"; echo "BOOTSTRAP_HOST=$BOOTSTRAP_HOST"; echo "BOOTSTRAP=$BOOTSTRAP"
```

### 2) 스크립트에 자동 주입 (sed — `^`로 줄 시작 고정해야 플레이스홀더의 `<>`까지 치환됨)
```bash
sed -i "s|^APP_ID=.*|APP_ID=\"$APP_ID\"|" mark2-3.sh
sed -i "s|^BOOTSTRAP_HOST=.*|BOOTSTRAP_HOST=\"$BOOTSTRAP_HOST\"|" mark2-3.sh
sed -i "s|^BOOTSTRAP=.*|BOOTSTRAP=\"$BOOTSTRAP\"|" mark2-3.sh

# 채워졌는지 확인 후 실행
grep -E "^APP_ID=|^BOOTSTRAP" mark2-3.sh
./mark2-3.sh
```

> ⚠️ `sed` 패턴은 반드시 `^APP_ID=.*` 처럼 줄 시작(`^`) 고정. (`APP_ID=".*"` 로 하면 플레이스홀더의 `<...>`가 따옴표 밖이라 치환 안 됨)
> ⚠️ 3-4는 app EC2에서 `kafka-topics.sh`를 SSM으로 실행 → 그 EC2에 kafka CLI 다운로드가 끝나 있어야 함.

## 채점 정보

| 항목         | 값                                              |
| ------------ | ----------------------------------------------- |
| VPC          | wsc-msk-vpc (10.0.0.0/16)                       |
| Bastion EC2  | wsc-bastion-ec2 (public, A존)                   |
| App EC2      | wsc-app-ec2 (t3.medium, public, A존)            |
| MSK Cluster  | msk-order-cluster (kafka.m5.large, 브로커 2개)  |
| S3 Bucket    | wsc-msk-order-data-**<비번호>**-bucket          |
| Lambda       | msk-order-consumer (python3.12, 256MB, 60s)     |
| DynamoDB     | order-records (PK: orderId S, SK: timestamp S)  |
| 트리거 토픽  | order-events (배치 100, TRIM_HORIZON)           |
