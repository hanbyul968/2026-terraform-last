# 제1과제 - Solution Architecture (ap-northeast-2)

## 실행 순서

### 1. Terraform 실행 (로컬)

```bash
cd C:\Users\competitor\2026-terraform\09\1과제
terraform init
terraform apply -auto-approve
```

> 완료까지 약 5~10분 소요 (VPC Endpoint 다수 생성)

---

### 2. Bastion 접속

```bash
# Bastion 퍼블릭 IP 확인
aws ec2 describe-instances --filters Name=tag:Name,Values=worldpay-bastion \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text

# SSH 접속 (패스워드 인증)
ssh ec2-user@<위에서 나온 IP>
# 패스워드: worldpay2026!
```

---

### 3. setup.sh 실행 (Bastion 내부)

```bash
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
mkdir -p /tmp/worldpay && cd /tmp/worldpay
aws s3 cp s3://$BUCKET/ . --recursive
chmod +x setup.sh
./setup.sh 2>&1 | tee /tmp/setup.log
```

> 완료까지 약 30~40분 소요

---

### 4. 완료 확인

```bash
# CloudFront 도메인
aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text

# Grafana URL
echo "http://$(aws elbv2 describe-load-balancers --names grafana-alb \
  --query 'LoadBalancers[0].DNSName' --output text)"
# admin / worldpay2026!

# API 테스트
CF=$(aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text)
curl -X POST https://$CF/v1/book \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"C001","username":"Alice","email":"a@a.com","concert_name":"Test"}'
```

---

### 5. 채점 스크립트 실행 (Bastion 내부)

```bash
aws configure set region ap-northeast-2
export BUCKET_NAME=worldpay-bucket-$(aws sts get-caller-identity --query Account --output text)
bash /home/ec2-user/mark.sh
```

---

### manifest 파일만 수정했을 때 재적용 (Terraform 없이)

```bash
# 로컬에서 S3 업로드
cd C:\Users\competitor\2026-terraform\09\1과제
terraform apply -auto-approve   # etag 변경 감지해서 S3만 업로드됨

# Bastion에서 재적용
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
cd /tmp/worldpay
aws s3 cp s3://$BUCKET/ . --recursive

# 예: fluentbit만 재적용 (ACCOUNT_ID 치환 필수)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" fluentbit.yaml
kubectl apply -f fluentbit.yaml
kubectl rollout restart daemonset worldpay-fluentbit -n logging

# 예: deployment만 재적용
kubectl apply -f deployment.yaml
kubectl rollout restart deployment book-deploy -n worldpay
```

---

### Terraform Import (리소스가 이미 존재할 때)

`terraform apply` 실행 시 리소스가 이미 존재한다는 오류가 나면 import로 state에 등록 후 재시도합니다.

```bash
# 공통 준비
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
```

#### VPC
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=worldpay-vpc --query "Vpcs[0].VpcId" --output text)
terraform import module.VPC.aws_vpc.this $VPC_ID
```

#### Subnet
```bash
# public subnet a
SID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-public-subnet-a --query "Subnets[0].SubnetId" --output text)
terraform import 'module.VPC.aws_subnet.public[0]' $SID

# public subnet c
SID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-public-subnet-c --query "Subnets[0].SubnetId" --output text)
terraform import 'module.VPC.aws_subnet.public[1]' $SID

# isolated subnet a
SID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-a --query "Subnets[0].SubnetId" --output text)
terraform import 'module.VPC.aws_subnet.isolated[0]' $SID

# isolated subnet c
SID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-c --query "Subnets[0].SubnetId" --output text)
terraform import 'module.VPC.aws_subnet.isolated[1]' $SID
```

#### Internet Gateway
```bash
IGW_ID=$(aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=worldpay-vpc-igw --query "InternetGateways[0].InternetGatewayId" --output text)
terraform import module.VPC.aws_internet_gateway.this $IGW_ID
```

#### KMS
```bash
DB_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName=='alias/worldpay-db-key'].TargetKeyId" --output text)
terraform import module.KMS.aws_kms_key.db $DB_KEY_ID
terraform import module.KMS.aws_kms_alias.db alias/worldpay-db-key

S3_KEY_ID=$(aws kms list-aliases --query "Aliases[?AliasName=='alias/worldpay-s3-key'].TargetKeyId" --output text)
terraform import module.KMS.aws_kms_key.s3 $S3_KEY_ID
terraform import module.KMS.aws_kms_alias.s3 alias/worldpay-s3-key
```

#### DynamoDB
```bash
terraform import module.DynamoDB.aws_dynamodb_table.this Concerts
terraform import module.DynamoDB.aws_dynamodb_contributor_insights.this Concerts
```

#### S3 (호스팅 버킷)
```bash
terraform import module.S3.aws_s3_bucket.this worldpay-bucket-$ACCOUNT
```

#### ECR
```bash
terraform import module.ECR.aws_ecr_repository.this worldpay-book
```

#### Bastion
```bash
# EIP
ALLOC_ID=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=worldpay-bastion-eip --query "Addresses[0].AllocationId" --output text)
terraform import aws_eip.bastion $ALLOC_ID

# IAM Role
terraform import aws_iam_role.bastion worldpay-bastion-role

# Instance
INSTANCE_ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=worldpay-bastion --query "Reservations[0].Instances[0].InstanceId" --output text)
terraform import aws_instance.bastion $INSTANCE_ID
```

#### ALB
```bash
BOOK_ALB_ARN=$(aws elbv2 describe-load-balancers --names book-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
terraform import aws_lb.book $BOOK_ALB_ARN

BOOK_TG_ARN=$(aws elbv2 describe-target-groups --names book-tg --query "TargetGroups[0].TargetGroupArn" --output text)
terraform import aws_lb_target_group.book $BOOK_TG_ARN

GRAFANA_ALB_ARN=$(aws elbv2 describe-load-balancers --names grafana-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
terraform import aws_lb.grafana $GRAFANA_ALB_ARN

GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
terraform import aws_lb_target_group.grafana $GRAFANA_TG_ARN
```

#### CloudWatch Log Group
```bash
terraform import aws_cloudwatch_log_group.app /worldpay/application
```

#### CloudFront
```bash
DIST_ID=$(for i in $(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text); do
  [ "$(aws cloudfront list-tags-for-resource \
    --resource arn:aws:cloudfront::${ACCOUNT}:distribution/$i \
    --query "Tags.Items[?Key=='Name'].Value|[0]" --output text)" = "worldpay-cdn" ] && echo $i && break
done)
terraform import module.CloudFront.aws_cloudfront_distribution.this $DIST_ID
```

#### Pod Identity IAM Role (Book)
```bash
terraform import aws_iam_role.book_app worldpay-book-app-role
```

---

# 수정 가이드 (대회 시 과제 변경 대응)

## 빠른 체크리스트 (시험 시작 시 확인 순서)

```
[ ] 프로젝트명/접두어 (worldpay → ?)
[ ] VPC CIDR (10.0.0.0/16 → ?)
[ ] 서브넷 CIDR 4개 및 이름
[ ] 가용영역 (2a/2c → ?)
[ ] EKS 버전 (1.35 → ?)
[ ] 노드 인스턴스 타입 (t3.large → ?)
[ ] DynamoDB 테이블명 / Partition Key
[ ] ECR 리포지토리명 / 이미지 태그
[ ] Bastion 인스턴스 타입 / 패스워드
[ ] CloudWatch Log Group 이름 / 보존기간
[ ] Grafana 패스워드 / datasource 이름
[ ] CloudFront API 경로 패턴 (/v1/*)
```

---

## 1. 프로젝트명 / 접두어 변경 (예: worldpay → newname)

전체에 걸쳐 `worldpay`가 하드코딩되어 있습니다. 아래 파일 모두 치환 필요.

| 파일 | 수정 위치 |
|------|----------|
| `main.tf` | 모든 `worldpay` 문자열 |
| `manifest/cluster.yaml` | `name: worldpay-cluster`, `worldpay-nodegroup`, `instanceName: worldpay-node` |
| `manifest/namespace.yaml` | namespace name |
| `manifest/deployment.yaml` | `namespace`, `name: book-deploy`, `name: book-sa` |
| `manifest/serviceaccount.yaml` | `name: book-sa`, `namespace` |
| `manifest/service.yaml` | `namespace` |
| `manifest/fluentbit.yaml` | DaemonSet name, namespace, log_group_name, 로그 경로 필터 |
| `manifest/grafana-values.yaml` | adminPassword, datasource name, dashboard title, log group ARN |
| `manifest/setup.sh` | 클러스터명, 역할명, 버킷명, 이미지 경로 전체 |

---

## 2. VPC / 네트워크 변경

### VPC CIDR 변경
- **`main.tf` 21번 줄** `vpc_cidr = "10.0.0.0/16"`
- **`manifest/setup.sh` 72번 줄** `--cidr 10.0.0.0/16` (EKS SG ingress 허용 범위)
- `modules/VPC/main.tf`의 VPC Endpoint SG ingress는 `var.vpc_cidr`을 참조하므로 자동 반영됨

### 서브넷 CIDR 변경
- **`main.tf` 21~22번 줄**
  ```hcl
  public_subnets_cidr   = ["10.0.0.0/24", "10.0.1.0/24"]
  isolated_subnets_cidr = ["10.0.2.0/24", "10.0.3.0/24"]
  ```

### 서브넷 이름 변경
- **`main.tf` 24~25번 줄**
  ```hcl
  public_subnet_names   = ["worldpay-public-subnet-a", "worldpay-public-subnet-c"]
  isolated_subnet_names = ["worldpay-isolated-subnet-a", "worldpay-isolated-subnet-c"]
  ```
- **`manifest/setup.sh` 48~49번 줄** `Values=worldpay-isolated-subnet-a`, `Values=worldpay-isolated-subnet-c`
- **`manifest/fluentbit.yaml` 43번 줄** INPUT Path `*_worldpay_*.log` → namespace 이름 기반이므로 namespace 변경 시 함께 수정

### 가용영역 변경 (예: 2a/2c → 2a/2b)
- **`main.tf` 23번 줄** `availability_zones = ["ap-northeast-2a", "ap-northeast-2c"]`
- **`manifest/cluster.yaml` 12~13번 줄** `ap-northeast-2a`, `ap-northeast-2c`

---

## 3. EKS 클러스터 변경

### 클러스터 이름 변경
- **`manifest/cluster.yaml` 5번 줄** `name: worldpay-cluster`
- **`manifest/setup.sh`** `worldpay-cluster` 전체 치환 (update-kubeconfig, create-access-entry, create-pod-identity-association 등)

### Kubernetes 버전 변경
- **`manifest/cluster.yaml` 7번 줄** `version: "1.35"`

### 노드 인스턴스 타입 변경
- **`manifest/cluster.yaml` 24번 줄** `instanceType: t3.large`
- **`manifest/setup.sh` 64번 줄** `--instance-types t3.large`

### 노드 최소/최대 수 변경
- **`manifest/cluster.yaml` 25~27번 줄** `desiredCapacity`, `minSize`, `maxSize`
- **`manifest/setup.sh` 64번 줄** `--scaling-config minSize=2,maxSize=4,desiredSize=2`

---

## 4. DynamoDB 변경

### 테이블 이름 변경
- **`main.tf` 38번 줄** `table_name = "Concerts"`
- **`manifest/deployment.yaml` 27번 줄** `value: "Concerts"` (TABLE_NAME 환경변수)

### Partition Key 변경
- **`main.tf` 39번 줄** `hash_key = "booking_id"`

### KMS 키 alias 변경
- **`main.tf` 31번 줄** `db_key_alias = "alias/worldpay-db-key"`

---

## 5. S3 / 호스팅 변경

### S3 버킷 이름 접두어 변경
- **`main.tf` 46번 줄** `bucket_name = "worldpay-bucket-${data.aws_caller_identity.current.account_id}"`

### KMS 키 alias 변경
- **`main.tf` 32번 줄** `s3_key_alias = "alias/worldpay-s3-key"`

---

## 6. ECR 변경

### 리포지토리 이름 변경
- **`main.tf` 53번 줄** `repository_name = "worldpay-book"`
- **`manifest/setup.sh` 27번 줄** `$ECR/worldpay-book:v1.0.0`
- **`manifest/deployment.yaml` 19번 줄** 이미지 경로 중 `worldpay-book`

### 이미지 태그 변경
- **`manifest/setup.sh` 26~27번 줄** `imageTag=v1.0.0`, `$ECR/worldpay-book:v1.0.0`
- **`manifest/deployment.yaml` 19번 줄** 이미지 경로 태그 `v1.0.0`

---

## 7. Bastion 변경

### 인스턴스 타입 변경
- **`main.tf` 113번 줄** `instance_type = "t3.small"`

### 로그인 패스워드 변경
- **`main.tf` 122번 줄** `echo 'ec2-user:worldpay2026!' | chpasswd`

---

## 8. CloudFront 변경

### Distribution 이름 변경
- **`main.tf` 332번 줄** `distribution_name = "worldpay-cdn"`

### OAC 이름 변경
- **`main.tf` 333번 줄** `oac_name = "worldpay-s3-oac"`

### API 경로 패턴 변경 (예: /v1/* → /api/*)
- **`modules/CloudFront/main.tf` 52번 줄** `path_pattern = "/v1/*"`

---

## 9. 로깅 (FluentBit) 변경

### Log Group 이름 변경
- **`main.tf` 289번 줄** `name = "/worldpay/application"`
- **`manifest/fluentbit.yaml` 83번 줄** `log_group_name    /worldpay/application`
- **`manifest/grafana-values.yaml` 57번 줄** log group ARN 경로 `/worldpay/application`

### Log Stream Prefix 변경
- **`manifest/fluentbit.yaml` 84번 줄** `log_stream_prefix book-`

### Log Retention 변경
- **`main.tf` 290번 줄** `retention_in_days = 7`

### 수집 대상 Namespace 변경
- **`manifest/fluentbit.yaml` 43번 줄** `Path /var/log/containers/*_worldpay_*.log` → 새 namespace로 수정

---

## 10. Grafana / Prometheus 변경

### Grafana 패스워드 변경
- **`manifest/grafana-values.yaml` 2번 줄** `adminPassword: "worldpay2026!"`

### Datasource 이름 변경
- **`manifest/grafana-values.yaml` 10번 줄** `name: worldpay-prometheus`
- **`manifest/grafana-values.yaml` 15번 줄** `name: worldpay-logs`
- **`manifest/grafana-values.yaml` 43, 50, 54, 62번 줄** 대시보드 패널 내 `"datasource"` 값도 동일하게 수정

### 대시보드 이름 변경
- **`manifest/grafana-values.yaml` 38번 줄** `"title": "worldpay-dashboard"`

### Prometheus 레플리카 수 변경
- **`manifest/prometheus-values.yaml` 2번 줄** `replicaCount: 2`

---

## 11. 앱 포트 변경 (8080 → 다른 포트)

| 파일 | 위치 |
|------|------|
| `manifest/deployment.yaml` | `containerPort`, livenessProbe/readinessProbe `port` |
| `main.tf` 208번 줄 | book ALB target group `port = 8080` |
| `main.tf` 217번 줄 | health_check `port = "8080"` |
| `manifest/setup.sh` 75번 줄 | EKS SG ingress `--port 8080` |
| `manifest/setup.sh` 128번 줄 | 타겟 등록 `Port=8080` |

---

## 12. Application 환경변수 변경

### AWS_REGION 변경
- **`manifest/deployment.yaml` 25번 줄** `value: "ap-northeast-2"`
- **`main.tf` 11번 줄** provider `region = "ap-northeast-2"`

### TABLE_NAME 변경
- **`manifest/deployment.yaml` 27번 줄** `value: "Concerts"`
- **`main.tf` 38번 줄** `table_name = "Concerts"` (위 4번 DynamoDB 항목과 동일)
