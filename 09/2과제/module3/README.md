# Module 3 - MSK (ap-northeast-3)

## 실행

```bash
# terraform.tfvars에 비번호 설정 (본인 비번호로 변경, PowerShell에서 실행)
Set-Content -Path terraform.tfvars -Value 'competitor_number = "01"' -Encoding utf8

terraform init
terraform apply --auto-approve
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

# 백그라운드 실행
nohup python3 /home/ec2-user/ec2_consumer.py \
  --bootstrap-servers $BOOTSTRAP \
  --bucket wsc-msk-order-data-<비번호>-bucket >> /home/ec2-user/consumer.log 2>&1 &
echo "Consumer PID: $!"
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

### 6. S3/DynamoDB 데이터 채우기 (채점 전 필수 — 별도 Producer 스크립트 없음, 선수가 직접 넣어야 함)

> Lambda가 DynamoDB에 저장, consumer가 S3에 저장. **채점 전 반드시 실행!**

```bash
# wsc-app-ec2 안에서 실행
for i in $(seq 1 100); do
  echo "{\"orderId\":\"order-$i-$(date +%s%N)\",\"timestamp\":\"2026-06-20T$(printf '%02d' $((i/3600))):$(printf '%02d' $(((i%3600)/60))):$(printf '%02d' $((i%60))).000Z\",\"region\":\"ap-northeast-3\",\"product\":{\"id\":\"P$(printf '%03d' $i)\",\"name\":\"상품-$i\",\"price\":$((i*1000))},\"quantity\":1,\"totalPrice\":$((i*1000)),\"status\":\"CREATED\"}" | \
  /home/ec2-user/kafka_2.13-3.5.1/bin/kafka-console-producer.sh \
    --bootstrap-server $BOOTSTRAP --topic order-events
done

# 10초 후 확인
sleep 10
aws dynamodb scan --table-name order-records \
  --select COUNT --query Count --output text --region ap-northeast-3
aws s3 ls s3://wsc-msk-order-data-<비번호>-bucket/orders/ --recursive | head -5
```

## 채점 시 변수 설정

채점스크립트에서 아래 변수를 실제 값으로 채워야 합니다:

```bash
# EC2 ID 확인
APP_ID=$(aws ec2 describe-instances --region ap-northeast-3 \
  --filters "Name=tag:Name,Values=wsc-app-ec2" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

# MSK 브로커 호스트 확인 (포트 제외)
CLUSTER_ARN=$(aws kafka list-clusters --region ap-northeast-3 \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
  --region ap-northeast-3 --query BootstrapBrokerString --output text)
BOOTSTRAP_HOST=$(echo $BOOTSTRAP | cut -d',' -f1 | cut -d':' -f1)
```

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
