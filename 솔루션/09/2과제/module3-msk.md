# 모듈 3 — MSK (콘솔 가이드)

**리전: ap-northeast-3 (오사카)** — 우측 상단에서 반드시 변경

> 목표: **MSK(Kafka)** → `order-events` 토픽 → **Lambda**가 소비해 **DynamoDB** 저장,
> 별도 **EC2 consumer**가 같은 토픽을 소비해 **S3**(파티션 구조)에 저장.

## 목표 리소스 이름
| 항목 | 값 |
|------|-----|
| VPC | `wsc-msk-vpc` (10.0.0.0/16), 퍼블릭/프라이빗 각 A·C 2개, NAT G/W |
| Bastion EC2 | `wsc-bastion-ec2` (public, A존) |
| App EC2 | `wsc-app-ec2` (t3.medium, public, A존) |
| MSK | `msk-order-cluster` (kafka.m5.large, 브로커 2, 100GiB) |
| 토픽 | `order-events`(3파티션,RF2), `order-events-dlq`(1,RF2) |
| S3 | `wsc-msk-order-data-<비번호>-bucket` |
| Lambda | `msk-order-consumer` (Python 3.12, 256MB, 60s, 트리거 order-events 배치100 TRIM_HORIZON) |
| DynamoDB | `order-records` (PK `orderId` S, SK `timestamp` S) |

---

## 1. VPC + 서브넷 (A, C존)

**VPC 콘솔 → VPC 생성 → "VPC 등 여러 리소스"**:
- 이름 `wsc-msk`, CIDR `10.0.0.0/16`
- AZ: **ap-northeast-3a, ap-northeast-3c** (2개)
- 퍼블릭 2, 프라이빗 2
- **NAT 게이트웨이: AZ당 1개** (프라이빗이 NAT로 통신해야 함)
- VPC 태그 이름을 `wsc-msk-vpc`로 확인
- 생성

예시 CIDR: public-a 10.0.1.0/24, public-c 10.0.2.0/24, private-a 10.0.3.0/24, private-c 10.0.4.0/24

---

## 2. 보안 그룹

- **MSK SG** `wsc-msk-sg`: 인바운드 TCP `9092` from `10.0.0.0/16` (+ 필요시 9094)
- **EC2 SG** `wsc-app-ec2-sg`: 인바운드 SSH 22 (또는 SSM만 쓰면 불필요), 아웃바운드 전체

## 3. S3 버킷

**S3 → 버킷 만들기**: 이름 `wsc-msk-order-data-<본인비번호>-bucket`, 리전 ap-northeast-3 → 생성

## 4. DynamoDB 테이블

**DynamoDB → 테이블 생성**:
- 이름 `order-records`
- 파티션 키 `orderId` (문자열)
- 정렬 키 `timestamp` (문자열)
- 온디맨드 → 생성

---

## 5. EC2 IAM 역할

**IAM → 역할 생성** (EC2 신뢰) → 이름 `wsc-app-ec2-role`:
- `AmazonSSMManagedInstanceCore`
- 인라인 정책:
  - S3: `s3:PutObject/GetObject/ListBucket` on 버킷 + `/*`
  - Kafka: `kafka:ListClusters`, `kafka:DescribeCluster`, `kafka:GetBootstrapBrokers`, `kafka:ListNodes` (`*`)
  - (검증 편의) `lambda:ListEventSourceMappings/UpdateEventSourceMapping`, `dynamodb:Scan/DescribeTable`

## 6. EC2 2대 (bastion, app)

**EC2 → 인스턴스 시작** ×2, 둘 다 AL2023, public-subnet-a, 퍼블릭 IP 켜기, IAM 프로파일 `wsc-app-ec2-role`:
- `wsc-bastion-ec2` (t3.micro)
- `wsc-app-ec2` (**t3.medium**)

**app EC2 사용자 데이터**(Java·Python·kafka-python·kafka CLI 설치, 배포파일 다운로드):
```bash
#!/bin/bash
dnf install -y java-11-amazon-corretto python3 python3-pip
python3 -m pip install kafka-python-ng boto3
# 배포파일(ec2_consumer.py, producer.py)을 S3나 스크립트로 배치
cd /home/ec2-user
curl -O https://archive.apache.org/dist/kafka/3.5.1/kafka_2.13-3.5.1.tgz
tar -xzf kafka_2.13-3.5.1.tgz && rm kafka_2.13-3.5.1.tgz
chown -R ec2-user:ec2-user /home/ec2-user/kafka_2.13-3.5.1
```
> kafka CLI(`kafka-topics.sh`)는 채점 3-4가 SSM으로 실행하므로 이 경로에 꼭 있어야 함.

---

## 7. MSK 클러스터 생성

**MSK 콘솔 → 클러스터 생성 → 사용자 지정 생성**:
- 이름 `msk-order-cluster`, 유형 프로비저닝
- Kafka 버전: 3.6.x (예: 3.6.0)
- 브로커: 유형 **kafka.m5.large**, AZ 2개, **AZ당 1브로커(총 2)**
- 스토리지: **100 GiB**
- 네트워킹: `wsc-msk-vpc`, **프라이빗 서브넷 a·c**, 보안그룹 `wsc-msk-sg`
- 액세스 제어: 일반 텍스트(PLAINTEXT) 허용 (또는 과제 요건대로)
- 퍼블릭 액세스: **비활성화**
- 생성 (15~25분)

## 8. 토픽 생성 (app EC2에서, MSK ACTIVE 후)

Session Manager로 `wsc-app-ec2` 접속:
```bash
CLUSTER_ARN=$(aws kafka list-clusters --region ap-northeast-3 --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN --region ap-northeast-3 --query BootstrapBrokerString --output text)

/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create --bootstrap-server $BOOTSTRAP --topic order-events --partitions 3 --replication-factor 2
/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create --bootstrap-server $BOOTSTRAP --topic order-events-dlq --partitions 1 --replication-factor 2
```

---

## 9. Lambda 역할 + 함수

**IAM 역할 `msk-order-consumer-role`** (Lambda 신뢰):
- 관리형 `AWSLambdaVPCAccessExecutionRole` (★ VPC Lambda ENI 권한)
- 인라인: `dynamodb:PutItem/GetItem` on 테이블, kafka/kafka-cluster 권한, logs 권한

**Lambda → 함수 생성**:
- 이름 `msk-order-consumer`, 런타임 **Python 3.12**, 역할 위 역할
- 메모리 **256MB**, 타임아웃 **60초**
- VPC: `wsc-msk-vpc`, 프라이빗 서브넷 a·c, 보안그룹 `wsc-msk-sg`
- 코드: 배포파일 `lambda.py` 업로드 (핸들러 `lambda.handler`)
- 환경변수: `DYNAMODB_TABLE_NAME=order-records`, `AWS_REGION_NAME=ap-northeast-3`

**MSK 트리거 추가** (함수 → 트리거 추가 → MSK):
- 클러스터 `msk-order-cluster`, 토픽 `order-events`
- 배치 크기 **100**, 시작 위치 **TRIM_HORIZON**
- 활성화 → 저장 (State가 Enabled 될 때까지 대기)

---

## 10. EC2 consumer 실행 (S3 저장)

`wsc-app-ec2`에서 배포파일 `ec2_consumer.py` 실행:
```bash
nohup python3 /home/ec2-user/ec2_consumer.py \
  --bootstrap-servers $BOOTSTRAP \
  --bucket wsc-msk-order-data-<비번호>-bucket \
  >> /tmp/consumer.log 2>&1 &
sleep 3 && cat /tmp/consumer.log
```

## 11. 데이터 채우기 (채점 전 필수)

배포파일 `producer.py`로 메시지 발행 → Lambda가 DynamoDB, consumer가 S3에 저장:
```bash
python3 /home/ec2-user/producer.py --bootstrap-servers $BOOTSTRAP --count 100 --interval 0

# 확인
aws dynamodb scan --table-name order-records --select COUNT --query Count --output text --region ap-northeast-3
aws s3 ls s3://wsc-msk-order-data-<비번호>-bucket/orders/ --recursive | head
```
S3 경로는 `orders/year=YYYY/month=MM/day=DD/....jsonl` (UTC).

---

## 자주 나는 오류
- **Lambda 생성 실패 `InsufficientRolePermissions`** → VPC Lambda가 ENI 만들 권한 부족. 역할에 `AWSLambdaVPCAccessExecutionRole` 붙이고 IAM 전파(30초) 후 재생성
- **Lambda ESM `Topic does not exist`** → 토픽 생성 전에 트리거가 폴링한 것. 토픽 만든 뒤 트리거 disable→enable 토글
- **`kafka:ListClusters AccessDenied`** (EC2) → EC2 역할에 kafka 권한 누락
- **kafka-topics.sh: No such file** → kafka CLI 미설치. 6단계 user_data / 수동 설치
- **`python3 ec2_consumer.py` argument required** → `--bootstrap-servers`, `--bucket` 인자 필수
- **consumer.log Permission denied** → home 디렉토리 권한 문제, `/tmp/consumer.log` 사용
