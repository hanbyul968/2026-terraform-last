# 제1과제 - Solution Architecture (WorldPay / ap-northeast-2)

2단계 구조로 구성되어 있습니다.

- **1단계 (로컬 PowerShell) — `bootstrap/`** : VPC(서브넷·IGW·라우팅·VPC Endpoint) + Bastion EC2 + 2단계 코드 배포용 S3 버킷
- **2단계 (Bastion bash) — `app/`** : KMS·DynamoDB·S3·ECR·ALB·CloudFront·IAM·LogGroup·manifest 버킷 (EKS/k8s 는 `manifest/setup.sh`)

> Full Private EKS(Public Endpoint 비활성)라서 kubectl·채점은 VPC 내부의 `worldpay-bastion` 에서만 가능합니다.
> 그래서 **VPC/Bastion 까지만 로컬에서 만들고, 나머지 AWS 리소스 + EKS 는 Bastion 안에서** 생성합니다.

---

## 디렉토리 구조

```
1과제/
├── bootstrap/          # ★ 1단계: 로컬에서 apply (VPC + Bastion + 코드버킷)
│   ├── main.tf
│   └── outputs.tf
├── app/                # ★ 2단계: Bastion 안에서 apply (나머지 전부)
│   ├── main.tf
│   └── outputs.tf
├── modules/            # 공용 모듈 (VPC, KMS, DynamoDB, S3, ECR, CloudFront)
├── manifest/           # k8s 매니페스트 + setup.sh (EKS 구축)
├── 배포파일/            # book 바이너리, index.html, main.jpeg
├── main.tf.OLD-single-stage      # (구) 단일스택 - 참고용, 사용 안 함
└── outputs.tf.OLD-single-stage   # (구) 단일스택 - 참고용, 사용 안 함
```

> ⚠️ **루트(`1과제/`)에서는 `terraform` 명령을 실행하지 마세요.**
> 과거 단일스택 시절의 `terraform.tfstate` 가 루트에 남아 있습니다. 루트에는 더 이상 활성 `.tf` 가 없으므로,
> 루트에서 `terraform plan/apply` 를 돌리면 **기존 리소스를 전부 삭제하려는 계획**이 생깁니다.
> 구 스택을 정리하려면: `main.tf.OLD-single-stage`/`outputs.tf.OLD-single-stage` 를 `.tf` 로 되돌린 뒤 `terraform destroy` → 그 후 `bootstrap`/`app` 으로 새로 진행.

---

## 실행 순서

### 1단계 — 로컬 PowerShell (Bastion 띄우기)

```powershell
cd C:\Users\competitor\2026-terraform\09\1과제\bootstrap
terraform init
terraform apply -auto-approve
```

출력값 확인:

```powershell
terraform output            # bastion_public_ip, code_bucket, ssh_command
```

> `bootstrap` 이 끝나면 Bastion user_data 가 자동으로
> ① awscli/kubectl/eksctl/**terraform**/git 설치, ② `app`·`modules`·`manifest`·`배포파일` 을 코드버킷에서
> `/home/ec2-user/project/` 로 내려받아 둡니다. (user_data 완료까지 1~2분)

### 2단계 — Bastion bash (나머지 apply)

```powershell
# 로컬에서 SSH (패스워드: worldpay2026!)
ssh ec2-user@<bastion_public_ip>
```

```bash
# user_data 가 코드를 받아둠. 못 받았으면 아래로 수동 다운로드:
#   BUCKET=$(cat ~/CODE_BUCKET.txt); aws s3 cp s3://$BUCKET/ ~/project --recursive --region ap-northeast-2

cd ~/project/app
terraform init
terraform apply -auto-approve      # KMS/DynamoDB/S3/ECR/ALB/CloudFront/IAM/LogGroup/manifest버킷
```

### 3단계 — Bastion bash (EKS + k8s 구축)

```bash
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
mkdir -p /tmp/worldpay && cd /tmp/worldpay
aws s3 cp s3://$BUCKET/ . --recursive
chmod +x setup.sh
./setup.sh 2>&1 | tee /tmp/setup.log     # 약 30~40분
```

### 4단계 — 완료 확인 (Bastion bash)

```bash
# CloudFront
aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text
# Grafana (admin / worldpay2026!)
echo "http://$(aws elbv2 describe-load-balancers --names grafana-alb --query 'LoadBalancers[0].DNSName' --output text)"
# API 테스트
CF=$(aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text)
curl -s -X POST https://$CF/v1/book -H 'Content-Type: application/json' \
  -d '{"client_id":"C001","username":"Alice","email":"a@a.com","concert_name":"Test"}' | jq .
```

### 5단계 — 채점 (Bastion bash)

```bash
aws configure set region ap-northeast-2
export BUCKET_NAME=worldpay-bucket-$(aws sts get-caller-identity --query Account --output text)
bash /home/ec2-user/mark.sh
```

---

## 재적용 / manifest 수정 후

**`app` 리소스 수정 시** — Bastion `~/project/app` 에서 `terraform apply` 다시 실행.

**manifest 파일 수정 시** — `app` 의 manifest 버킷은 `terraform apply` 시 etag 변경분만 재업로드됩니다.

```bash
cd ~/project/app && terraform apply -auto-approve      # 변경된 manifest 만 S3 재업로드
cd /tmp/worldpay
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
aws s3 cp s3://$BUCKET/ . --recursive
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml fluentbit.yaml
kubectl apply -f deployment.yaml
kubectl rollout restart deployment book-deploy -n worldpay
```

> ⚠️ `bootstrap` 의 코드버킷은 **로컬에서 `bootstrap` 을 다시 apply** 해야 갱신됩니다(로컬 `app/*.tf` 변경분 업로드). Bastion 안에서 `app/*.tf` 를 직접 고친 경우엔 그 파일을 그대로 쓰면 됩니다.

---

# 📌 수정 가이드 (대회 시 과제 변경 대응 / 최대 30%)

> 모든 라인 번호는 현재 파일 기준입니다. 값 변경 시 **연관된 모든 파일**을 함께 수정해야 채점이 통과합니다.
> "단계" = 어디서 apply 하는지: **로컬=bootstrap**, **Bastion=app/manifest**.

## 0. 시험 시작 시 체크리스트

```
[ ] 프로젝트 접두어        worldpay → ?
[ ] 리전                   ap-northeast-2 → ?
[ ] VPC CIDR               10.0.0.0/16 → ?
[ ] 서브넷 CIDR/이름/AZ     10.0.0~3.0/24, a/c → ?
[ ] DynamoDB 테이블/PK     Concerts / booking_id → ?
[ ] ECR 리포 / 이미지태그   worldpay-book / v1.0.0 → ?
[ ] EKS 이름/버전/노드타입  worldpay-cluster / 1.35 / t3.large → ?
[ ] 앱 포트                8080 → ?
[ ] Log Group / 보존       /worldpay/application / 7 → ?
[ ] Grafana 비번/DS 이름   worldpay2026! / worldpay-prometheus·worldpay-logs → ?
[ ] CloudFront 이름/OAC/경로 worldpay-cdn / worldpay-s3-oac / /v1/* → ?
[ ] Bastion 타입/비번      t3.small / worldpay2026! → ?
```

---

## 1. 프로젝트 접두어 (worldpay → newname)
전체 하드코딩. 아래 파일에서 `worldpay` 전부 치환.

| 단계 | 파일 | 비고 |
|------|------|------|
| bootstrap | `bootstrap/main.tf` | VPC 이름·서브넷 이름·Bastion 리소스·태그 |
| app | `app/main.tf` | VPC/서브넷 **조회 필터(L28·L39·L50)**, 모든 리소스명·alias·태그 |
| manifest | `manifest/setup.sh` | 클러스터/역할/버킷/이미지/서브넷 이름 전부 |
| manifest | `manifest/cluster.yaml` | `name: worldpay-cluster`, nodegroup, instanceName |
| manifest | `manifest/deployment.yaml`,`serviceaccount.yaml`,`service.yaml` | namespace·이름·이미지 |
| manifest | `manifest/fluentbit.yaml` | DaemonSet명, namespace, log_group, 로그경로필터(L43) |
| manifest | `manifest/grafana-values.yaml` | datasource명, 대시보드명, log group ARN |

> ⚠️ `bootstrap/main.tf` 의 서브넷/VPC 이름과 `app/main.tf` 의 **data source 필터값(L28·L39·L50)** 은 **반드시 동일**해야 합니다. 다르면 2단계에서 VPC/서브넷을 못 찾아 apply 실패합니다.

---

## 2. 리전 변경 (ap-northeast-2 → 다른 리전)
- **`bootstrap/main.tf` L22** `region = "ap-northeast-2"`
- **`app/main.tf` L18** provider region
- **`manifest/setup.sh` L4** `REGION=ap-northeast-2`
- **`manifest/cluster.yaml` L6** `region: ap-northeast-2`
- **`manifest/deployment.yaml` L25** `AWS_REGION` 값
- **`manifest/fluentbit.yaml`** `[OUTPUT] region` (L84 부근)
- **`modules/VPC/main.tf`** VPC Endpoint `service_name` 의 `com.amazonaws.ap-northeast-2.*` (locals + s3/dynamodb) — 리전 문자열 하드코딩이므로 전부 치환
- AZ도 함께 변경 (아래 4번)

---

## 3. VPC / 네트워크

### VPC CIDR (`10.0.0.0/16`)
- **`bootstrap/main.tf` L29** `vpc_cidr`
- **`manifest/setup.sh` L73** `--cidr 10.0.0.0/16` (EKS SG 443 ingress)
- VPC Endpoint SG ingress 는 `var.vpc_cidr` 참조 → 자동 반영

### 서브넷 CIDR
- **`bootstrap/main.tf` L30** `public_subnets_cidr`
- **`bootstrap/main.tf` L31** `isolated_subnets_cidr`

### 서브넷 이름
- **`bootstrap/main.tf` L33-34** `public_subnet_names`, `isolated_subnet_names`
- **`app/main.tf` L39** public 서브넷 조회 필터
- **`app/main.tf` L50** isolated 서브넷 조회 필터
- **`manifest/setup.sh` L49-50** isolated 서브넷 이름(EKS 노드 배치)

### VPC 이름
- **`bootstrap/main.tf` L28** `vpc_name`
- **`app/main.tf` L28** VPC 조회 필터
- **`manifest/setup.sh`** `Values=worldpay-vpc` (cluster.yaml placeholder 치환부)

### 가용영역 (2a/2c → 2a/2b 등)
- **`bootstrap/main.tf` L32** `availability_zones`
- **`manifest/cluster.yaml` L13-14** `ap-northeast-2a/2c`

---

## 4. Bastion
- 인스턴스 타입: **`bootstrap/main.tf` L138** `instance_type = "t3.small"`
- 로그인 비번: **`bootstrap/main.tf` L154** `echo 'ec2-user:worldpay2026!'`
- Bastion terraform 버전: **`bootstrap/main.tf` L174** (1.13.4)

---

## 5. DynamoDB
- 테이블명: **`app/main.tf` L64** `table_name = "Concerts"` + **`manifest/deployment.yaml` L27** `TABLE_NAME` 값
- Partition Key: **`app/main.tf` L65** `hash_key = "booking_id"`
- KMS alias: **`app/main.tf` L57** `db_key_alias`

## 6. S3 호스팅
- 버킷명 접두어: **`app/main.tf` L72** `bucket_name`
- KMS alias: **`app/main.tf` L58** `s3_key_alias`
- (정적파일 업로드는 `manifest/setup.sh` 의 `HOSTING_BUCKET` + `app` manifest 버킷)

## 7. ECR
- 리포명: **`app/main.tf` L79** `repository_name = "worldpay-book"`
  - **`manifest/setup.sh` L27-28** `$ECR/worldpay-book:v1.0.0`
  - **`manifest/deployment.yaml` L19** 이미지 경로
- 이미지 태그(v1.0.0): **`manifest/setup.sh` L27-28**, **`manifest/deployment.yaml` L19**

---

## 8. EKS (manifest 영역)
- 클러스터명: **`manifest/cluster.yaml` L5** + `manifest/setup.sh` 전체
- K8s 버전: **`manifest/cluster.yaml` L7** `version: "1.35"`
- 노드 인스턴스 타입: **`manifest/cluster.yaml` L24** + **`manifest/setup.sh` L65** `--instance-types t3.large`
- 노드 수: **`manifest/cluster.yaml` L25-27**(desired/min/max) + **`manifest/setup.sh` L65** `--scaling-config`

---

## 9. Load Balancer / 앱 포트
- book ALB TG 포트: **`app/main.tf` L165** `port = 8080`, 헬스체크 **L173** `port = "8080"`
- grafana ALB TG 포트: **`app/main.tf` L219** `port = 3000`
- 앱 포트(8080) 변경 시 함께:
  - **`manifest/deployment.yaml` L22** `containerPort`, liven/readiness probe 포트
  - **`manifest/setup.sh` L76** EKS SG ingress `--port 8080`
- grafana 포트(3000) 변경 시 **`manifest/setup.sh` L77** `--port 3000`

---

## 10. CloudFront
- Distribution명: **`app/main.tf` L287** `distribution_name = "worldpay-cdn"`
- OAC명: **`app/main.tf` L288** `oac_name = "worldpay-s3-oac"`
- API 경로 패턴(/v1/* → /api/* 등): **`modules/CloudFront/main.tf` L53** `path_pattern = "/v1/*"`
- Default Root Object: `modules/CloudFront/main.tf` `default_root_object = "index.html"`

---

## 11. Logging (FluentBit)
- Log Group명: **`app/main.tf` L244** `name = "/worldpay/application"`
  - **`manifest/fluentbit.yaml` L85** `log_group_name`
  - **`manifest/grafana-values.yaml`** APP_LOGS 패널 log group ARN (L57 부근)
- 보존기간: **`app/main.tf` L245** `retention_in_days = 7`
- Log Stream Prefix: **`manifest/fluentbit.yaml` L86** `log_stream_prefix book-`
- 수집 대상 namespace: **`manifest/fluentbit.yaml` L43** `Path .../*_worldpay_*.log`

---

## 12. Monitoring (Grafana / Prometheus)
- Grafana 비번: **`manifest/grafana-values.yaml` L2** `adminPassword`
- Datasource명: **`manifest/grafana-values.yaml` L10** `worldpay-prometheus`, **L15** `worldpay-logs`
  - 대시보드 패널의 `"datasource"` 값도 동일하게 수정
- 대시보드명/패널명(POD_CPU 등): `manifest/grafana-values.yaml` 의 dashboards JSON
- Prometheus 레플리카: **`manifest/prometheus-values.yaml` L2** `replicaCount`

---

# Terraform Import (리소스가 이미 존재할 때)

`bootstrap` / `app` 각 디렉토리에서 해당 리소스만 import 후 재 apply.

```powershell
# 예) bootstrap 에서 VPC import
$VPC_ID = aws ec2 describe-vpcs --filters Name=tag:Name,Values=worldpay-vpc --query "Vpcs[0].VpcId" --output text
terraform import module.VPC.aws_vpc.this $VPC_ID
```

```bash
# 예) app 에서 DynamoDB / ECR / ALB import
terraform import module.DynamoDB.aws_dynamodb_table.this Concerts
terraform import module.ECR.aws_ecr_repository.this worldpay-book
terraform import aws_lb.book $(aws elbv2 describe-load-balancers --names book-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
terraform import aws_cloudwatch_log_group.app /worldpay/application
```

> VPC/Subnet 은 **bootstrap** state, 그 외는 **app** state 에 들어갑니다. import 대상 디렉토리를 혼동하지 마세요.
