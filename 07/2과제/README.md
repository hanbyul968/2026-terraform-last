# 2과제: Small Challenges — 실행 가이드

> **모든 모듈(1~4)이 루트 단일 구성으로 통합되어 있습니다. `terraform apply` 한 번이면 4개 리전 인프라가 전부 생성됩니다.**
> provider alias(seoul/tokyo/singapore/oregon)로 리전별 리소스를 한 state에서 관리합니다.

---

## 0. 준비 (CloudShell)

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

## 1. 단일 apply (모듈 1~4 인프라 전부)

```bash
terraform init
terraform apply -var="docdb_password=Skills2026!" -auto-approve
```

⏱ EKS 클러스터 때문에 전체 ~20분 소요. 이 한 번으로:
- 모듈1: DocumentDB + Client EC2(앱 자동 설치·seed·인덱스) — 서울
- 모듈2: VPC Lattice + Client/Service EC2(앱 자동 기동) — 도쿄
- 모듈3: SNS/Lambda/CloudTrail/EventBridge — 싱가포르
- 모듈4: EKS/Fargate/SQS/IRSA + CoreDNS Fargate 패치 — 오레곤

> apply 중 모듈4의 `null_resource.coredns_fargate`가 CloudShell의 `kubectl`로 CoreDNS를 패치합니다. **apply 전에 아래 kubectl이 설치돼 있어야 이 단계가 동작합니다.** (없으면 apply 후 수동 patch 필요)

```bash
# (권장) apply 전에 kubectl 미리 설치
EKS_VER=1.31   # 대략값. 클러스터 생성 후 정확값으로 맞춰도 됨
curl -LO "https://dl.k8s.io/release/v${EKS_VER}.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

---

## 2. 모듈4 K8s 레이어 (apply 후 1회)

EKS 위의 KEDA/Karpenter/Worker는 Helm·kubectl·Docker가 필요해 terraform 밖에서 실행합니다.

```bash
# kubectl (위에서 안 했다면)
EKS_VER=$(aws eks describe-cluster --region us-west-2 --name skills-sqs-cluster --query 'cluster.version' --output text)
curl -LO "https://dl.k8s.io/release/v${EKS_VER}.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Docker 로그인 (Worker 이미지 빌드·푸시용)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com

# K8s 리소스 배포 (반드시 2과제 루트에서 실행 — terraform output 참조)
bash k8s-apply.sh
```

`k8s-apply.sh`가 하는 일: namespace 생성 → KEDA/Karpenter Helm 설치 → Worker SA/Deployment → KEDA ScaledObject/TriggerAuthentication → Karpenter NodePool/EC2NodeClass → 서브넷 태깅 → ECR 이미지 빌드·푸시.

---

## 3. 확인

```bash
# 모듈1
IP=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
curl http://$IP:8080/health && curl http://$IP:8080/v1/admin/summary

# 모듈2
IP=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
curl http://$IP/health && curl "http://$IP/v1/client/orders?id=1001"

# 모듈3 (Inbound 0개여야 함)
aws ec2 describe-security-groups --region ap-southeast-1 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query "SecurityGroups[].IpPermissions" --output json

# 모듈4
aws eks update-kubeconfig --region us-west-2 --name skills-sqs-cluster
kubectl get pod -n keda; kubectl get pod -n karpenter
```

---

## 파일 구조

```
07/2과제/
├── provider.tf      # aws alias 4개(seoul/tokyo/singapore/oregon) + tls/null/archive
├── variables.tf     # docdb_password
├── module1.tf       # DocumentDB (ap-northeast-2)
├── module2.tf       # VPC Lattice (ap-northeast-1)
├── module3.tf       # EventBridge+Lambda (ap-southeast-1)
├── module4.tf       # EKS+SQS (us-west-2) + CoreDNS 패치
├── app/             # 앱 소스 (제공 배포파일 그대로)
├── k8s-apply.sh     # 모듈4 K8s 배포 (루트에서 실행)
└── README.md
```

---

## 배점 (총 30점)

| 모듈 | 항목 | 배점 |
|------|------|------|
| 1 | DocumentDB based NoSQL Application | 7.5 |
| 2 | VPC Lattice | 7.5 |
| 3 | Cloud Event Handling | 7.5 |
| 4 | EKS + SQS + KEDA + Karpenter | 7.5 |

---

## 대회 당일 변경 대응 가이드 (최대 30% 변경 상정)

리소스 이름(`skills-*`)은 고정값이므로 변경하지 않습니다.
**모든 .tf는 루트에 통합**되어 있으니 해당 파일에서 바로 수정합니다.

### 모듈1 — `module1.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| VPC CIDR | `aws_vpc.m1` → `cidr_block` | `10.1.0.0/16` |
| Public 서브넷 CIDR | `aws_subnet.m1_public` → `cidr_block` | `10.1.1.0/24` |
| Private 서브넷 CIDR | `aws_subnet.m1_private` → `cidr_block` | `10.1.10~11.0/24` |
| DocDB 인스턴스 클래스 | `aws_docdb_cluster_instance.m1` → `instance_class` | `db.t3.medium` |
| DocDB 마스터 계정 | `aws_docdb_cluster.m1.master_username` + `aws_secretsmanager_secret_version.m1` 내 `username` | `skillsadmin` |
| DocDB 비밀번호 | `variables.tf` → `default` (또는 `-var`) | `Skills2026!` |
| Backup 보존기간 | `aws_docdb_cluster.m1` → `backup_retention_period` | `1` |
| EC2 인스턴스 타입 | `aws_instance.m1_client` → `instance_type` | `t3.small` |
| Client App 포트 | `aws_security_group.m1_ec2` ingress `from_port/to_port` | `8080` |

### 모듈2 — `module2.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| Client VPC CIDR | `aws_vpc.m2_client.cidr_block` **+** `aws_security_group.m2_lattice_assoc.ingress.cidr_blocks` (두 곳) | `10.61.0.0/16` |
| Service VPC CIDR | `aws_vpc.m2_service` → `cidr_block` | `10.62.0.0/16` |
| Client 서브넷 CIDR | `aws_subnet.m2_client` → `cidr_block` | `10.61.1.0/24` |
| Service 서브넷 CIDR | `aws_subnet.m2_service` → `cidr_block` | `10.62.1.0/24` |
| Service App 포트 | `aws_security_group.m2_service` ingress + `aws_vpclattice_target_group.m2` config.port + `..._attachment.m2` target.port (세 곳) | `8080` |
| Client App 포트 | `aws_security_group.m2_client` ingress + `aws_vpclattice_listener.m2` → `port` (두 곳) | `80` |
| EC2 인스턴스 타입 | `aws_instance.m2_client`, `aws_instance.m2_service` → `instance_type` | `t3.micro` |

### 모듈3 — `module3.tf`

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| VPC CIDR | `aws_vpc.m3` → `cidr_block` | `10.73.0.0/16` |
| 서브넷 CIDR | `aws_subnet.m3` → `cidr_block` | `10.73.1.0/24` |
| EC2 인스턴스 타입 | `aws_instance.m3` → `instance_type` | `t3.micro` |
| Lambda Runtime | `aws_lambda_function.m3` → `runtime` | `python3.12` |
| Lambda Timeout | `aws_lambda_function.m3` → `timeout` | `30` |

### 모듈4 — `module4.tf` + `k8s-apply.sh`

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| VPC CIDR | `module4.tf` | `aws_vpc.m4` → `cidr_block` | `10.4.0.0/16` |
| Public 서브넷 CIDR | `module4.tf` | `aws_subnet.m4_public` → `"10.4.${count.index}.0/24"` | `10.4.0~1.0/24` |
| Private 서브넷 CIDR | `module4.tf` | `aws_subnet.m4_private` → `"10.4.${count.index + 10}.0/24"` | `10.4.10~11.0/24` |
| SQS Visibility Timeout | `module4.tf` | `aws_sqs_queue.m4` → `visibility_timeout_seconds` | `60` |
| Fargate Profile 이름 | `module4.tf` | `aws_eks_fargate_profile.m4_keda / m4_karpenter` → `fargate_profile_name` | `skills-sqs-fp-keda / -karpenter` |
| Karpenter 버전 | `k8s-apply.sh` | `helm ... karpenter ... --version` | `1.4.0` |
| KEDA queueLength | `k8s-apply.sh` | ScaledObject → `queueLength` | `"2"` |
| KEDA pollingInterval | `k8s-apply.sh` | ScaledObject → `pollingInterval` | `15` |
| KEDA cooldownPeriod | `k8s-apply.sh` | ScaledObject → `cooldownPeriod` | `30` |
| KEDA maxReplicaCount | `k8s-apply.sh` | ScaledObject → `maxReplicaCount` | `6` |
| NodePool instance 타입 | `k8s-apply.sh` | NodePool → `instance-type values` | `["t3.medium","t3.large"]` |
| NodePool consolidateAfter | `k8s-apply.sh` | NodePool → `consolidateAfter` | `30s` |
| Worker PROCESSING_SECONDS | `k8s-apply.sh` | Deployment env | `"5"` |

### 리전 변경

`provider.tf`의 해당 alias 블록 `region` 수정.

| 모듈 | alias | 현재 리전 |
|------|-------|-----------|
| 1 | `seoul` | `ap-northeast-2` |
| 2 | `tokyo` | `ap-northeast-1` |
| 3 | `singapore` | `ap-southeast-1` |
| 4 | `oregon` | `us-west-2` |

추가로:
- 모듈2 리전 변경 시 `module2.tf`의 `data.aws_ec2_managed_prefix_list.lattice` → `name = "com.amazonaws.<NEW_REGION>.vpc-lattice"`
- 모듈4 리전 변경 시 `module4.tf`의 `aws_ec2_tag`·`null_resource.coredns_fargate`·서브넷 태그(`kubernetes.io/cluster/...`) 안의 `us-west-2`/클러스터명, `k8s-apply.sh` 상단 `REGION=`, 모듈1 user_data·confirm 명령들의 리전도 함께 확인

### 비번호가 필요한 리소스 (Global Unique)

- 모듈3 CloudTrail S3 버킷: `module3.tf` → `aws_s3_bucket.m3_trail` → `bucket_prefix = "skills-ceh-trail-"`
  - 비번호 지정 시: `bucket = "skills-ceh-trail-<비번호>"` 로 변경
