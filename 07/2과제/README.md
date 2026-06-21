# 2과제: Small Challenges — 실행 가이드

## 0. 공통 준비 (CloudShell)

```bash
# Terraform 설치
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform

# 소스 클론
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/07/2과제
```

---

## 1모듈 — DocumentDB (서울, ap-northeast-2) ⏱ ~10분

```bash
cd module1
terraform init
terraform apply -var="docdb_password=Skills2026!" -auto-approve
cd ..
```

**자동으로 되는 것:** EC2 userdata가 앱 설치 → 앱 기동(포트 8080) → 데이터 seed → 인덱스 생성까지 모두 처리합니다.

**확인 (apply 완료 후 2~3분 대기):**
```bash
IP=$(aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

curl http://$IP:8080/health
curl http://$IP:8080/v1/admin/summary
```

---

## 2모듈 — VPC Lattice (도쿄, ap-northeast-1) ⏱ ~3분

```bash
cd module2
terraform init
terraform apply -auto-approve
cd ..
```

**자동으로 되는 것:** Service EC2는 포트 8080으로 앱 기동, Client EC2는 VPC Lattice domain을 자동 조회하여 `SERVICE_URL` 설정 후 포트 80으로 앱 기동합니다.

**확인:**
```bash
IP=$(aws ec2 describe-instances --region ap-northeast-1 \
  --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

curl http://$IP/health
curl "http://$IP/v1/client/orders?id=1001"
```

---

## 3모듈 — Cloud Event Handling (싱가포르, ap-southeast-1) ⏱ ~3분

```bash
cd module3
terraform init
terraform apply -auto-approve
cd ..
```

**자동으로 되는 것:** VPC, EC2, protected-SG(inbound 0개), SNS, Lambda, CloudTrail, EventBridge 전부 생성됩니다.

**확인:**
```bash
aws ec2 describe-security-groups --region ap-southeast-1 \
  --filters Name=tag:Name,Values=skills-ceh-protected-sg \
  --query "SecurityGroups[].IpPermissions" --output json
# 결과: []  (빈 배열이어야 함)
```

---

## 4모듈 — EKS + KEDA + Karpenter (오레곤, us-west-2) ⏱ ~20분

### 4-1. Terraform apply

```bash
cd module4
terraform init
terraform apply -auto-approve
cd ..
```

**자동으로 되는 것:** VPC, EKS 클러스터, Fargate Profile 3개(kube-system/keda/karpenter), SQS, OIDC, IRSA Role 4개 생성됩니다.

### 4-2. kubectl 설치

```bash
EKS_VER=$(aws eks describe-cluster --region us-west-2 --name skills-sqs-cluster \
  --query 'cluster.version' --output text)
curl -LO "https://dl.k8s.io/release/v${EKS_VER}.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

### 4-3. Helm 설치

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 4-4. Docker 로그인 (Worker 이미지 빌드용)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com
```

### 4-5. K8s 리소스 배포

```bash
bash k8s-apply.sh
```

**k8s-apply.sh가 하는 것:**
1. namespace 생성 (keda / karpenter / skills-sqs)
2. KEDA Helm 설치 (`keda-operator` SA에 IRSA annotation 주입)
3. Karpenter Helm 설치 v1.4.0
4. Worker ServiceAccount 생성 (IRSA annotation)
5. Worker Deployment 배포 (replicas: 0)
6. KEDA TriggerAuthentication / ScaledObject 배포
7. Karpenter NodePool / EC2NodeClass 배포
8. 서브넷 태그 추가 (`kubernetes.io/cluster/skills-sqs-cluster=owned`)
9. ECR에 Worker 이미지 빌드 & 푸시

**확인:**
```bash
aws eks update-kubeconfig --region us-west-2 --name skills-sqs-cluster
kubectl get nodes -l eks.amazonaws.com/compute-type=fargate
kubectl get pod -n keda
kubectl get pod -n karpenter
```

---

## 전체 실행 순서 요약

```
module1 apply → (2~3분 대기) → 확인
module2 apply → 확인
module3 apply → 확인
module4 apply → kubectl/helm 설치 → k8s-apply.sh → 확인
```

---

## 대회 당일 변경 대응 가이드 (최대 30% 변경 상정)

리소스 이름(`skills-*`)은 고정값이므로 변경하지 않습니다.

---

### 모듈1 — `module1/module1.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| VPC CIDR | `aws_vpc.m1` → `cidr_block` | `10.1.0.0/16` |
| Public 서브넷 CIDR | `aws_subnet.m1_public` → `cidr_block` | `10.1.1.0/24` |
| Private 서브넷 CIDR | `aws_subnet.m1_private` → `cidr_block = "10.1.${count.index + 10}.0/24"` | `10.1.10~11.0/24` |
| DocDB 인스턴스 클래스 | `aws_docdb_cluster_instance.m1` → `instance_class` | `db.t3.medium` |
| DocDB 마스터 계정 | `aws_docdb_cluster.m1.master_username` + `aws_secretsmanager_secret_version.m1` 내 `username` | `skillsadmin` |
| DocDB 비밀번호 | `module1/variables.tf` → `default` (또는 `-var` 인수) | `Skills2026!` |
| Backup 보존기간 | `aws_docdb_cluster.m1` → `backup_retention_period` | `1` |
| EC2 인스턴스 타입 | `aws_instance.m1_client` → `instance_type` | `t3.small` |
| Client App 포트 | `aws_security_group.m1_ec2` ingress `from_port/to_port` | `8080` |

---

### 모듈2 — `module2/module2.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| Client VPC CIDR | `aws_vpc.m2_client` → `cidr_block` **+** `aws_security_group.m2_lattice_assoc` → `ingress.cidr_blocks` (두 곳) | `10.61.0.0/16` |
| Service VPC CIDR | `aws_vpc.m2_service` → `cidr_block` | `10.62.0.0/16` |
| Client 서브넷 CIDR | `aws_subnet.m2_client` → `cidr_block` | `10.61.1.0/24` |
| Service 서브넷 CIDR | `aws_subnet.m2_service` → `cidr_block` | `10.62.1.0/24` |
| Service App 포트 | `aws_security_group.m2_service` ingress + `aws_vpclattice_target_group.m2` config.port + `aws_vpclattice_target_group_attachment.m2` target.port (세 곳) | `8080` |
| Client App 포트 | `aws_security_group.m2_client` ingress + `aws_vpclattice_listener.m2` → `port` (두 곳) | `80` |
| EC2 인스턴스 타입 | `aws_instance.m2_client`, `aws_instance.m2_service` → `instance_type` | `t3.micro` |

> Client VPC CIDR 변경 시 `aws_vpc.m2_client.cidr_block`과 `aws_security_group.m2_lattice_assoc.ingress.cidr_blocks` **두 곳** 모두 수정

---

### 모듈3 — `module3/module3.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| VPC CIDR | `aws_vpc.m3` → `cidr_block` | `10.73.0.0/16` |
| 서브넷 CIDR | `aws_subnet.m3` → `cidr_block` | `10.73.1.0/24` |
| EC2 인스턴스 타입 | `aws_instance.m3` → `instance_type` | `t3.micro` |
| Lambda Runtime | `aws_lambda_function.m3` → `runtime` | `python3.12` |
| Lambda Timeout | `aws_lambda_function.m3` → `timeout` | `30` |

---

### 모듈4 — `module4/module4.tf` + `k8s-apply.sh`

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| VPC CIDR | `module4/module4.tf` | `aws_vpc.m4` → `cidr_block` | `10.4.0.0/16` |
| Public 서브넷 CIDR | `module4/module4.tf` | `aws_subnet.m4_public` → `"10.4.${count.index}.0/24"` | `10.4.0~1.0/24` |
| Private 서브넷 CIDR | `module4/module4.tf` | `aws_subnet.m4_private` → `"10.4.${count.index + 10}.0/24"` | `10.4.10~11.0/24` |
| SQS Visibility Timeout | `module4/module4.tf` | `aws_sqs_queue.m4` → `visibility_timeout_seconds` | `60` |
| Karpenter 버전 | `k8s-apply.sh` | `helm upgrade --install karpenter ... --version` | `1.4.0` |
| KEDA queueLength | `k8s-apply.sh` | ScaledObject → `queueLength` | `"2"` |
| KEDA pollingInterval | `k8s-apply.sh` | ScaledObject → `pollingInterval` | `15` |
| KEDA cooldownPeriod | `k8s-apply.sh` | ScaledObject → `cooldownPeriod` | `30` |
| KEDA maxReplicaCount | `k8s-apply.sh` | ScaledObject → `maxReplicaCount` | `6` |
| NodePool instance 타입 | `k8s-apply.sh` | NodePool → `node.kubernetes.io/instance-type values` | `["t3.medium","t3.large"]` |
| NodePool consolidateAfter | `k8s-apply.sh` | NodePool → `consolidateAfter` | `30s` |
| Worker PROCESSING_SECONDS | `k8s-apply.sh` | Deployment env → `PROCESSING_SECONDS value` | `"5"` |

---

### Fargate Profile 이름 변경

`module4/module4.tf`에서:
- `aws_eks_fargate_profile.m4_keda` → `fargate_profile_name` (현재: `skills-sqs-fp-keda`)
- `aws_eks_fargate_profile.m4_karpenter` → `fargate_profile_name` (현재: `skills-sqs-fp-karpenter`)

---

### 리전 변경

각 모듈의 `provider.tf` → `region` 수정

| 모듈 | 파일 | 현재 리전 |
|------|------|-----------|
| 1 | `module1/provider.tf` | `ap-northeast-2` |
| 2 | `module2/provider.tf` | `ap-northeast-1` |
| 3 | `module3/provider.tf` | `ap-southeast-1` |
| 4 | `module4/provider.tf` + `k8s-apply.sh` 상단 `REGION=` | `us-west-2` |

모듈2 리전 변경 시 `module2/module2.tf`의 VPC Lattice prefix list 이름도 수정:
```hcl
# data.aws_ec2_managed_prefix_list.lattice
name = "com.amazonaws.<NEW_REGION>.vpc-lattice"
```

---

### 비번호가 필요한 리소스 (Global Unique)

- 모듈3 CloudTrail S3 버킷: `module3/module3.tf` → `aws_s3_bucket.m3_trail` → `bucket_prefix = "skills-ceh-trail-"`
  - 비번호 지정 시: `bucket = "skills-ceh-trail-<비번호>"` 로 변경
