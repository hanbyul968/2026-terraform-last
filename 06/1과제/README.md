# 1과제 실행 가이드

---

## Step 1 — 로컬에서 Terraform 실행

```bash
cd C:\Users\competitor\2026-terraform\06\1과제
terraform init
terraform apply --auto-approve
# 프롬프트에서 비번호 입력 (예: 103)
```

> 생성되는 주요 리소스: VPC / KMS / S3 / DynamoDB / ECR / Lambda / ALB / CloudFront / WAF / IAM / Grafana ALB / CloudShell SG / manifest S3 버킷

---

## Step 2 — CloudShell VPC Environment 생성 (콘솔 수동)

AWS 콘솔 → CloudShell → VPC Environment 생성

| 항목 | 값 |
|---|---|
| Name | `unicorn-mark` |
| VPC | `unicorn-vpc` |
| Subnet | Private Subnet 아무거나 |
| Security Group | `unicorn-mark-sg` |

---

## Step 3 — CloudShell 접속 후 실행

```bash
# 1. 환경변수 설정
export number=<비번호>

# 2. AWS 자격증명 설정 (default region: ap-northeast-2)
aws configure

# 3. S3에서 파일 다운로드 + apply.sh 실행 (한 줄)
aws s3 cp s3://$(aws s3 ls | grep unicorn-manifest | awk '{print $3}')/ ./ --recursive && source apply.sh
```

> CloudShell 세션 만료로 끊기면 다시 접속 후 동일 명령어 재실행

**apply.sh 자동 처리 목록:**

| 순서 | 내용 |
|---|---|
| 1 | book 이미지 빌드 & ECR push (v1.0.0, latest) |
| 2 | ECR IMMUTABLE_WITH_EXCLUSION 설정 (latest 제외) |
| 3 | eksctl로 EKS 클러스터 생성 (`unicorn-eks-cluster`) |
| 4 | EKS 클러스터 SG에 CloudShell SG / VPC CIDR 인바운드 허용 |
| 5 | kubectl apply (namespace → SA → deployment → service → fluentd → fluent-bit) |
| 6 | EC2 노드에 Name 태그 부여 |
| 7 | Pod Identity Association 생성 |
| 8 | Pod 재기동 + ALB Target Group에 Pod IP 등록 |
| 9 | Helm으로 Prometheus + Grafana 설치 (monitoring namespace) |
| 10 | Grafana ALB Target Group에 addon 노드 등록 |
| 11 | 노드 Role에 CloudWatchLogsFullAccess 부여 / 현재 IAM 유저에 Audit Role AssumeRole 권한 부여 |

---

## Step 4 — Grafana 대시보드 생성 (수동)

### 접속

브라우저 → `unicorn-grafana-alb` DNS 주소

| Userid | Password |
|---|---|
| `skills<비번호>` | `HelloKrSkills!<비번호>@` |

### Dashboard 생성

Dashboard Name: **`unicorn-grafana-dashboard`**

| # | Panel Name | Panel Type | PromQL |
|---|:---|:---|:---|
| 1 | EKS Node CPU Usage (%) | Time series | `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| 2 | EKS Node Memory Usage (%) | Time series | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| 3 | unicorn Namespace Pod Status | Stat | `sum by (phase) ( kube_pod_status_phase{ namespace="unicorn" } )` |
| 4 | Book App Ready Pods | Stat | `count( kube_pod_status_ready{ namespace="unicorn", condition="true", pod=~"unicorn-book-app.*" } == 1 )` |
| 5 | Book App HTTP Request Duration | Time series | `quantile(0.<퍼센타일>, rate(container_cpu_usage_seconds_total{namespace="unicorn", container="book"}[5m])) * 1000` |

> Panel 3은 Stat + graph 포함. 패널 순서, 이름 대소문자는 채점 시 무시.

---

## Terraform Import (state 유실 시)

> `terraform apply` 실패 후 리소스가 이미 AWS에 존재할 때 state에 등록하는 명령어입니다.
> 모든 명령어는 `-var="number=<비번호>"` 필요합니다.

### 사전 변수 설정

```bash
NUM=<비번호>   # 예: 103
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2

# VPC / Subnet / NAT / RT
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text)
PUB_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-a --query "Subnets[0].SubnetId" --output text)
PUB_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-b --query "Subnets[0].SubnetId" --output text)
PUB_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-c --query "Subnets[0].SubnetId" --output text)
PRIV_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-a --query "Subnets[0].SubnetId" --output text)
PRIV_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-b --query "Subnets[0].SubnetId" --output text)
PRIV_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-c --query "Subnets[0].SubnetId" --output text)
IGW=$(aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=unicorn-igw --query "InternetGateways[0].InternetGatewayId" --output text)
EIP_A=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-a --query "Addresses[0].AllocationId" --output text)
EIP_B=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-b --query "Addresses[0].AllocationId" --output text)
EIP_C=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-c --query "Addresses[0].AllocationId" --output text)
NAT_A=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-a --query "NatGateways[0].NatGatewayId" --output text)
NAT_B=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-b --query "NatGateways[0].NatGatewayId" --output text)
NAT_C=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-c --query "NatGateways[0].NatGatewayId" --output text)
RT_PUB=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-pub --query "RouteTables[0].RouteTableId" --output text)
RT_PRIV_A=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-a --query "RouteTables[0].RouteTableId" --output text)
RT_PRIV_B=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-b --query "RouteTables[0].RouteTableId" --output text)
RT_PRIV_C=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-c --query "RouteTables[0].RouteTableId" --output text)
FLOWLOG=$(aws ec2 describe-flow-logs --filter Name=resource-id,Values=$VPC_ID --query "FlowLogs[0].FlowLogId" --output text)
VPCE_S3=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$REGION.s3 --query "VpcEndpoints[0].VpcEndpointId" --output text)
VPCE_ECR_API=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$REGION.ecr.api --query "VpcEndpoints[0].VpcEndpointId" --output text)
VPCE_ECR_DKR=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$REGION.ecr.dkr --query "VpcEndpoints[0].VpcEndpointId" --output text)
SG_VPCE=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=unicorn-vpc-vpce-sg --query "SecurityGroups[0].GroupId" --output text)

# KMS
KMS_APP=$(aws kms describe-key --key-id alias/unicorn-kms-app --query "KeyMetadata.KeyId" --output text)
KMS_DATA=$(aws kms describe-key --key-id alias/unicorn-kms-data --query "KeyMetadata.KeyId" --output text)
KMS_PLATFORM=$(aws kms describe-key --key-id alias/unicorn-kms-platform --query "KeyMetadata.KeyId" --output text)
KMS_REPLICA=$(aws kms describe-key --key-id alias/unicorn-kms-platform --region us-east-1 --query "KeyMetadata.KeyId" --output text)

# S3
BUCKET=unicorn-web-$ACCOUNT
MANIFEST_BUCKET=$(aws s3 ls | grep unicorn-manifest | awk '{print $3}')

# Lambda / SG
LAMBDA_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-get-booking-func-sg --query "SecurityGroups[0].GroupId" --output text)

# ALB
ALB_ARN=$(aws elbv2 describe-load-balancers --names unicorn-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-alb-sg --query "SecurityGroups[0].GroupId" --output text)
TG_APP_ARN=$(aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text)
TG_LAMBDA_ARN=$(aws elbv2 describe-target-groups --names unicorn-alb-lambda-tg --query "TargetGroups[0].TargetGroupArn" --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[0].ListenerArn" --output text)
RULE_HEALTH_ARN=$(aws elbv2 describe-rules --listener-arn $LISTENER_ARN --query "Rules[?Priority=='5'].RuleArn" --output text)
RULE_LAMBDA_ARN=$(aws elbv2 describe-rules --listener-arn $LISTENER_ARN --query "Rules[?Priority=='10'].RuleArn" --output text)

# Grafana ALB
G_ALB_ARN=$(aws elbv2 describe-load-balancers --names unicorn-grafana-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
G_ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-grafana-alb-sg --query "SecurityGroups[0].GroupId" --output text)
G_TG_ARN=$(aws elbv2 describe-target-groups --names unicorn-grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
G_LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $G_ALB_ARN --query "Listeners[0].ListenerArn" --output text)

# CloudShell SG
CLOUDSHELL_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-mark-sg --query "SecurityGroups[0].GroupId" --output text)

# CloudFront
CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].Id|[0]" --output text)
OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='s3-oac'].Id|[0]" --output text)
VPC_ORIGIN_ID=$(aws cloudfront list-vpc-origins --query "VpcOriginList.Items[?Name=='app-origin'].Id|[0]" --output text)
WAF_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='unicorn-waf'].Id|[0]" --output text)
WAF_ARN=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name=='unicorn-waf'].ARN|[0]" --output text)
```

### VPC

```bash
TF="terraform import -var=\"number=$NUM\""

$TF module.VPC.aws_vpc.unicorn                          $VPC_ID
$TF module.VPC.aws_subnet.public[0]                     $PUB_A
$TF module.VPC.aws_subnet.public[1]                     $PUB_B
$TF module.VPC.aws_subnet.public[2]                     $PUB_C
$TF module.VPC.aws_subnet.private[0]                    $PRIV_A
$TF module.VPC.aws_subnet.private[1]                    $PRIV_B
$TF module.VPC.aws_subnet.private[2]                    $PRIV_C
$TF module.VPC.aws_internet_gateway.unicorn             $IGW
$TF module.VPC.aws_eip.nat[0]                           $EIP_A
$TF module.VPC.aws_eip.nat[1]                           $EIP_B
$TF module.VPC.aws_eip.nat[2]                           $EIP_C
$TF module.VPC.aws_nat_gateway.unicorn[0]               $NAT_A
$TF module.VPC.aws_nat_gateway.unicorn[1]               $NAT_B
$TF module.VPC.aws_nat_gateway.unicorn[2]               $NAT_C
$TF module.VPC.aws_route_table.public                   $RT_PUB
$TF module.VPC.aws_route_table.private[0]               $RT_PRIV_A
$TF module.VPC.aws_route_table.private[1]               $RT_PRIV_B
$TF module.VPC.aws_route_table.private[2]               $RT_PRIV_C
$TF module.VPC.aws_route_table_association.public[0]    "$PUB_A/$RT_PUB"
$TF module.VPC.aws_route_table_association.public[1]    "$PUB_B/$RT_PUB"
$TF module.VPC.aws_route_table_association.public[2]    "$PUB_C/$RT_PUB"
$TF module.VPC.aws_route_table_association.private[0]   "$PRIV_A/$RT_PRIV_A"
$TF module.VPC.aws_route_table_association.private[1]   "$PRIV_B/$RT_PRIV_B"
$TF module.VPC.aws_route_table_association.private[2]   "$PRIV_C/$RT_PRIV_C"
$TF module.VPC.aws_flow_log.unicorn                     $FLOWLOG
$TF module.VPC.aws_cloudwatch_log_group.flow_log        "/aws/vpc-flow-log/unicorn-vpc"
$TF module.VPC.aws_iam_role.flow_log                    "unicorn-vpc-flow-log-role"
$TF module.VPC.aws_iam_role_policy.flow_log             "unicorn-vpc-flow-log-role:unicorn-vpc-flow-log-policy"
$TF module.VPC.aws_security_group.vpc_endpoint          $SG_VPCE
$TF module.VPC.aws_vpc_endpoint.s3                      $VPCE_S3
$TF module.VPC.aws_vpc_endpoint.ecr_api                 $VPCE_ECR_API
$TF module.VPC.aws_vpc_endpoint.ecr_dkr                 $VPCE_ECR_DKR
```

### KMS

```bash
$TF module.KMS.aws_kms_key.app                          $KMS_APP
$TF module.KMS.aws_kms_key.data                         $KMS_DATA
$TF module.KMS.aws_kms_key.platform                     $KMS_PLATFORM
$TF module.KMS.aws_kms_alias.app                        "alias/unicorn-kms-app"
$TF module.KMS.aws_kms_alias.data                       "alias/unicorn-kms-data"
$TF module.KMS.aws_kms_alias.platform                   "alias/unicorn-kms-platform"
$TF module.KMS.aws_kms_replica_key.platform_replica     $KMS_REPLICA
$TF module.KMS.aws_kms_alias.platform_replica           "alias/unicorn-kms-platform"
```

### S3

```bash
$TF module.S3.aws_s3_bucket.frontend                                    $BUCKET
$TF module.S3.aws_s3_bucket_versioning.frontend                         $BUCKET
$TF module.S3.aws_s3_bucket_server_side_encryption_configuration.frontend $BUCKET
$TF module.S3.aws_s3_bucket_public_access_block.frontend                $BUCKET
$TF module.CloudFront.aws_s3_bucket_policy.cloudfront                   $BUCKET
$TF aws_s3_bucket.manifest                                               $MANIFEST_BUCKET
```

### DynamoDB / ECR

```bash
$TF module.DynamoDB.aws_dynamodb_table.concert          "unicorn-concert-db"
$TF module.ECR.aws_ecr_repository.concert_app           "unicorn-concert-app"
```

### Lambda

```bash
$TF module.Lambda.aws_lambda_function.this              "unicorn-get-booking-func"
$TF module.Lambda.aws_cloudwatch_log_group.lambda       "/unicorn/lambda/get-booking"
$TF module.Lambda.aws_iam_role.lambda                   "unicorn-get-booking-func-role"
$TF module.Lambda.aws_iam_role_policy.lambda            "unicorn-get-booking-func-role:unicorn-get-booking-func-policy"
$TF module.Lambda.aws_security_group.lambda             $LAMBDA_SG
```

### ALB

```bash
$TF module.ALB.aws_lb.this                              $ALB_ARN
$TF module.ALB.aws_security_group.alb                   $ALB_SG
$TF module.ALB.aws_lb_target_group.app                  $TG_APP_ARN
$TF module.ALB.aws_lb_target_group.lambda               $TG_LAMBDA_ARN
$TF module.ALB.aws_lb_listener.http                     $LISTENER_ARN
$TF module.ALB.aws_lb_listener_rule.health              $RULE_HEALTH_ARN
$TF module.ALB.aws_lb_listener_rule.lambda_get          $RULE_LAMBDA_ARN
```

### CloudFront / WAF

```bash
$TF module.CloudFront.aws_cloudfront_distribution.this              $CF_ID
$TF module.CloudFront.aws_cloudfront_origin_access_control.s3       $OAC_ID
$TF module.CloudFront.aws_cloudfront_vpc_origin.alb                 $VPC_ORIGIN_ID
$TF module.CloudFront.aws_cloudwatch_log_group.waf                  "aws-waf-logs-unicorn"
$TF module.CloudFront.aws_wafv2_web_acl.this                        "$WAF_ID/unicorn-waf/CLOUDFRONT"
$TF module.CloudFront.aws_wafv2_web_acl_logging_configuration.this  $WAF_ARN
```

### IAM / Security

```bash
$TF module.IAM.aws_iam_role.audit                       "unicorn-audit-role"
$TF module.IAM.aws_iam_role_policy.audit                "unicorn-audit-role:unicorn-audit-role-policy"
$TF aws_iam_role.book_app                               "unicorn-book-app-role"
$TF aws_iam_role_policy.book_app                        "unicorn-book-app-role:unicorn-book-app-policy"
```

### CloudWatch / 기타

```bash
$TF aws_cloudwatch_log_group.book_app                   "/unicorn/eks/book-app"
$TF aws_security_group.cloudshell                       $CLOUDSHELL_SG
$TF aws_security_group.grafana_alb                      $G_ALB_SG
$TF aws_lb.grafana                                      $G_ALB_ARN
$TF aws_lb_target_group.grafana                         $G_TG_ARN
$TF aws_lb_listener.grafana                             $G_LISTENER_ARN
```

> `aws_security_group_rule.alb_from_cloudfront` 와 `aws_s3_object.*` 는 import 불필요 — apply 시 자동 생성됩니다.

---

## 과제 변경 시 수정 위치 가이드

> 대회 당일 과제지가 최대 30% 변경될 수 있으므로 아래 표를 참고해 해당 파일만 수정하세요.

### 빠른 체크리스트 (과제지 받은 직후 확인)

- [ ] VPC CIDR → `main.tf` `module "VPC"` `vpc_cidr`
- [ ] 서브넷 CIDR/이름/AZ 수 → `main.tf` `module "VPC"` 리스트 전체
- [ ] KMS alias / 교체주기 → `main.tf` `module "KMS"`
- [ ] S3 버킷 이름 규칙 → `main.tf` `module "S3"` `bucket_name`
- [ ] DynamoDB 테이블명 / PK / GSI → `main.tf` `module "DynamoDB"` + `manifest/deployment.yaml` TABLE_NAME
- [ ] ECR 레포 이름 / 이미지 태그 → `main.tf` + `manifest/apply.sh` + `manifest/deployment.yaml`
- [ ] EKS 클러스터명 / 버전 / 노드 스펙 → `manifest/cluster.yaml`
- [ ] Lambda 함수명 / 로그 그룹 → `main.tf` `module "Lambda"`
- [ ] ALB / TG / Grafana ALB 이름 → `main.tf`
- [ ] WAF rate limit (횟수/시간) → `modules/CloudFront/waf.tf`
- [ ] Audit Role 이름 / External ID 형식 → `main.tf` `module "IAM"`
- [ ] App 포트 / Health 경로 → `manifest/deployment.yaml`, `manifest/service.yaml`
- [ ] Grafana 계정 형식 → `manifest/apply.sh`

---

### 1. VPC / 네트워크

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| VPC CIDR (현재: `10.97.0.0/16`) | `main.tf` | `module "VPC"` → `vpc_cidr` |
| VPC CIDR 변경 시 추가 | `manifest/apply.sh` | 62번째 줄 `--cidr 10.97.0.0/16` |
| Public 서브넷 CIDR (현재: 0, 1, 2번째 /24) | `main.tf` | `module "VPC"` → `public_subnets_cidr` |
| Private 서브넷 CIDR (현재: 10, 11, 12번째 /24) | `main.tf` | `module "VPC"` → `private_subnets_cidr` |
| VPC / 서브넷 / IGW / NAT / RT 이름 | `main.tf` | `module "VPC"` → 각 `_name` / `_names` 변수 |
| AZ 수 변경 (3→2 등) | `main.tf` | `module "VPC"` 안의 리스트 변수 개수를 모두 맞춤 |

---

### 2. KMS

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 키 alias (app / data / platform) | `main.tf` | `module "KMS"` → `app_key_alias`, `data_key_alias`, `platform_key_alias` |
| platform alias 변경 시 추가 | `modules/KMS/replica.tf` | `aws_kms_alias.platform_replica` → `name` |
| platform alias 변경 시 추가 | `manifest/apply.sh` | 31번째 줄 `alias/unicorn-kms-platform` |
| 교체 주기 (현재: `90`일) | `main.tf` | `module "KMS"` → `rotation_period` |

---

### 3. S3

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 버킷 이름 (현재: `unicorn-web-<ACCOUNT_ID>`) | `main.tf` | `module "S3"` → `bucket_name` |
| 암호화 키 변경 | `main.tf` | `module "S3"` → `kms_key_arn` |

---

### 4. DynamoDB

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 테이블 이름 (현재: `unicorn-concert-db`) | `main.tf` | `module "DynamoDB"` → `table_name` |
| 테이블 이름 변경 시 추가 | `manifest/deployment.yaml` | `env` → `TABLE_NAME` |
| Partition Key (현재: `booking_id`) | `main.tf` | `module "DynamoDB"` → `hash_key` |
| GSI 이름 (현재: `client-id-created-at-index`) | `main.tf` | `module "DynamoDB"` → `gsi_name` |
| GSI PK / SK / Projection | `main.tf` | `module "DynamoDB"` → `gsi_hash_key`, `gsi_range_key`, `gsi_projection` |

---

### 5. ECR

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 레포 이름 (현재: `unicorn-concert-app`) | `main.tf` | `module "ECR"` → `repository_name` |
| 레포 이름 변경 시 추가 | `manifest/apply.sh` | 44번째 줄 `ECR_URL`, 51번째 줄 `--repository-name` |
| 이미지 태그 (현재: `v1.0.0`, `latest`) | `manifest/apply.sh` | 47번째 줄 `docker build/push` 태그 |
| 이미지 태그 변경 시 추가 | `manifest/deployment.yaml` | `image:` 줄 태그 부분 |

---

### 6. EKS

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 클러스터 이름 (현재: `unicorn-eks-cluster`) | `manifest/cluster.yaml` | `metadata.name` |
| 클러스터 이름 변경 시 추가 | `main.tf` | `aws_iam_role.book_app` → `aws:SourceArn` / `aws_eks_pod_identity_association` → `cluster_name` / `module "IAM"` → `eks_cluster_arn` |
| 클러스터 이름 변경 시 추가 | `manifest/apply.sh` | 59, 63, 64, 66, 67, 86, 90, 93, 94번째 줄 |
| EKS 버전 (현재: `1.35`) | `manifest/cluster.yaml` | `metadata.version` |
| 노드 인스턴스 타입 (현재: `t3.medium`) | `manifest/cluster.yaml` | `managedNodeGroups[].instanceType` |
| 노드 수 (app-ng: 2, addon-ng: 1) | `manifest/cluster.yaml` | `desiredCapacity`, `minSize`, `maxSize` |
| 노드 레이블 (`unicorn: app/addon`) | `manifest/cluster.yaml` | `managedNodeGroups[].labels` |
| 노드 레이블 변경 시 추가 | `manifest/deployment.yaml` | `nodeSelector` |
| 노드 레이블 변경 시 추가 | `manifest/fluentd.yaml` | Deployment `nodeSelector` |
| 노드 레이블 변경 시 추가 | `manifest/apply.sh` | 78~83번째 줄 `-l unicorn=app/addon` / 118번째 줄 |
| App Namespace (현재: `unicorn`) | `manifest/namespace.yaml` | `metadata.name` |
| Namespace 변경 시 추가 | `manifest/deployment.yaml`, `service.yaml`, `serviceaccount.yaml`, `fluent-bit.yaml`, `fluentd.yaml` | 각 파일 `namespace:` 필드 |
| Namespace 변경 시 추가 | `manifest/apply.sh` | 86번째 줄 `--namespace`, 96번째 줄 `-n unicorn` |
| Namespace 변경 시 추가 | `main.tf` | `aws_eks_pod_identity_association` → `namespace` |

---

### 7. Lambda

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 함수 이름 (현재: `unicorn-get-booking-func`) | `main.tf` | `module "Lambda"` → `function_name` |
| 로그 그룹 (현재: `/unicorn/lambda/get-booking`) | `main.tf` | `module "Lambda"` → `log_group_name` |
| 암호화 키 변경 | `main.tf` | `module "Lambda"` → `kms_key_arn` |
| Lambda 코드 수정 | `modules/Lambda/index.py` | 직접 수정 (zip은 terraform이 자동 재생성) |

---

### 8. ALB / CloudFront / WAF

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| ALB 이름 (현재: `unicorn-alb`) | `main.tf` | `module "ALB"` → `alb_name` |
| ALB TG 이름 (현재: `unicorn-tg`) | `main.tf` | `module "ALB"` → `tg_name` |
| ALB TG 이름 변경 시 추가 | `manifest/apply.sh` | 95번째 줄 `--names unicorn-tg` |
| Grafana ALB 이름 (현재: `unicorn-grafana-alb`) | `main.tf` | `aws_lb.grafana` → `name` |
| Grafana TG 이름 (현재: `unicorn-grafana-tg`) | `main.tf` | `aws_lb_target_group.grafana` → `name` |
| Grafana TG 이름 변경 시 추가 | `manifest/apply.sh` | 117번째 줄 `--names unicorn-grafana-tg` |
| Grafana NodePort (현재: `30300`) | `main.tf` | `aws_lb_target_group.grafana` → `port`, `health_check.port` |
| Grafana NodePort 변경 시 추가 | `manifest/apply.sh` | 109번째 줄 `nodePort=30300`, 119번째 줄 `Port=30300` |
| CloudFront 이름 (현재: `unicorn-svc-cf`) | `main.tf` | `module "CloudFront"` → `distribution_comment` |
| WAF 이름 (현재: `unicorn-waf`) | `main.tf` | `module "CloudFront"` → `waf_name` |
| WAF Rate Limit (현재: `50`회 / `60`초) | `modules/CloudFront/waf.tf` | `rate_based_statement` → `limit`, `evaluation_window_sec` |
| S3 정적 캐싱 경로 (현재: `/static/*`) | `modules/CloudFront/main.tf` | `ordered_cache_behavior` → `path_pattern` |

---

### 9. IAM Audit Role

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| Role 이름 (현재: `unicorn-audit-role`) | `main.tf` | `module "IAM"` → `role_name` |
| External ID (현재: `unicorn-audit-2026<비번호>`) | `main.tf` | `module "IAM"` → `external_id` 문자열 |

---

### 10. Application

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| App 포트 (현재: `8080`) | `manifest/deployment.yaml` | `containerPort`, Probe `port` |
| App 포트 변경 시 추가 | `manifest/service.yaml` | `targetPort` |
| App 포트 변경 시 추가 | `manifest/apply.sh` | 97번째 줄 `Port=8080` |
| Health 경로 (현재: `/health`) | `manifest/deployment.yaml` | Liveness/Readiness `path` |
| Health 경로 변경 시 추가 | `modules/ALB/main.tf` | `aws_lb_target_group.app` → `health_check.path` |
| API 경로 (현재: `/v1/book`) | `modules/ALB/main.tf` | `aws_lb_listener_rule.lambda_get` → `path_pattern` |
| ServiceAccount 이름 (현재: `unicorn-book-app-sa`) | `manifest/serviceaccount.yaml` | `metadata.name` |
| SA 이름 변경 시 추가 | `manifest/deployment.yaml`, `manifest/fluent-bit.yaml`, `manifest/fluentd.yaml` | `serviceAccountName` |
| SA 이름 변경 시 추가 | `manifest/apply.sh` | 87번째 줄 `--service-account` |
| SA 이름 변경 시 추가 | `main.tf` | `aws_eks_pod_identity_association` → `service_account` |
| Deployment 이름 (현재: `unicorn-book-app-deploy`) | `manifest/deployment.yaml` | `metadata.name` |
| Deployment 이름 변경 시 추가 | `manifest/fluent-bit.yaml` | `Path` 패턴 `unicorn-book-app-deploy-*` |
| Deployment 이름 변경 시 추가 | `manifest/apply.sh` | 93, 94번째 줄 |
| Grafana 계정 형식 | `manifest/apply.sh` | 106~107번째 줄 `adminUser`, `adminPassword` |

---

### 11. Observability

**로그 파이프라인: Fluent Bit (DaemonSet / 모든 노드) → Fluentd (Deployment / addon 노드) → CloudWatch Logs**

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| Fluentd 연결 주소 / 포트 | `manifest/fluent-bit.yaml` | `[OUTPUT]` → `Host`, `Port` |
| Health 로그 제외 필터 | `manifest/fluent-bit.yaml` | `[FILTER] grep Exclude log /health` |
| CW 로그 그룹 (현재: `/unicorn/eks/book-app`) | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `log_group_name` |
| 로그 그룹 변경 시 추가 | `main.tf` | `aws_cloudwatch_log_group.book_app` → `name` |
| Fluentd flush 간격 (현재: `10s`) | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `<buffer>` → `flush_interval` |
| Fluentd region | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `region` + Deployment env `AWS_REGION` |
| Fluentd nodeSelector (현재: `addon`) | `manifest/fluentd.yaml` | Deployment → `nodeSelector.unicorn` |
| monitoring namespace (현재: `monitoring`) | `manifest/monitoring-ns.yaml` | `metadata.name` |

---

### 12. 공통

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| AWS 리전 (현재: `ap-northeast-2`) | `main.tf` | `provider "aws"` → `region` |
| 리전 변경 시 추가 | `manifest/cluster.yaml` | `metadata.region` |
| 리전 변경 시 추가 | `manifest/deployment.yaml` | env `AWS_REGION` |
| 리전 변경 시 추가 | `manifest/apply.sh` | 8번째 줄 `REGION=`, 47번째 줄 ECR URL 리전 |
| 비번호 | `terraform apply` | 프롬프트 입력 또는 `-var="number=<비번호>"` |
