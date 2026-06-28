# 2과제: Small Challenges — 실행 가이드 (Windows + Bastion)

> **terraform apply 한 번**이면 4개 리전 인프라 전부 + **us-west-2 bastion EC2**까지 생성됩니다.
> bastion이 부팅하면서 **CoreDNS 패치 + KEDA/Karpenter/Worker 배포(k8s-apply.sh)를 자동 실행**합니다.
> → Windows에서 terraform만 돌리면 끝. CloudShell·로컬 kubectl/helm/docker 불필요.

---

## 0. 준비 (Windows / PowerShell)

```powershell
# Terraform & AWS CLI 설치 (한 번만)
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI

# AWS 자격증명 설정 (대회 지급 계정)
aws configure        # Access Key / Secret / region=us-west-2

# 소스
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform\07\2과제
```

---

## 1. 단일 apply (인프라 전부 + bastion)

```powershell
terraform init
terraform apply -var="docdb_password=Skills2026!" -auto-approve
```

⏱ EKS + bastion 부트스트랩까지 전체 ~25분. 이 한 번으로:
- 모듈1: DocumentDB + Client EC2(앱 자동 설치·seed·인덱스) — 서울
- 모듈2: VPC Lattice + Client/Service EC2(앱 자동 기동) — 도쿄
- 모듈3: SNS/Lambda/CloudTrail/EventBridge — 싱가포르
- 모듈4: EKS/Fargate/SQS/IRSA + **bastion EC2** — 오레곤

**bastion이 자동으로 하는 일** (user_data → `k8s-apply.sh`):
CoreDNS Fargate 패치 → KEDA/Karpenter Helm 설치 → Worker SA/Deployment → KEDA ScaledObject/TriggerAuth → Karpenter NodePool/EC2NodeClass → 서브넷 태깅 → ECR 이미지 빌드·푸시.

> terraform은 **인프라까지만** 책임지고(apply 완료), bastion의 K8s 배포는 **백그라운드로 몇 분 더** 걸립니다. 아래 2번으로 완료를 확인하세요.

---

## 2. bastion 진행상황 확인 (apply 후)

bastion은 인바운드 없이 **SSM**으로만 접속합니다(키페어 불필요).

```powershell
# bastion 인스턴스 ID
$BASTION = terraform output -raw bastion_instance_id

# 부트스트랩 로그 실시간 확인 (SSM Session)
aws ssm start-session --target $BASTION --region us-west-2
#  (세션 안에서)
sudo tail -f /var/log/skills-bastion-bootstrap.log
#  마지막에 "BASTION_BOOTSTRAP_DONE" 나오면 완료
```

완료되면 bastion 세션 안에서 바로 검증 가능:

```bash
# bastion 안에서 (kubectl/helm 이미 설치·인증됨)
kubectl get pod -n keda
kubectl get pod -n karpenter
kubectl get deploy sqs-worker -n skills-sqs
```

> **재실행이 필요하면** bastion에서:
> ```bash
> cd /root/2026-terraform/07/2과제 && git pull && bash k8s-apply.sh
> ```

---

## 3. 확인 (Windows / PowerShell)

```powershell
# 모듈1
$IP = aws ec2 describe-instances --region ap-northeast-2 --filters "Name=tag:Name,Values=skills-nosql-client-ec2" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PublicIpAddress" --output text
curl "http://${IP}:8080/health"; curl "http://${IP}:8080/v1/admin/summary"

# 모듈2
$IP = aws ec2 describe-instances --region ap-northeast-1 --filters "Name=tag:Name,Values=skills-lattice-client-ec2" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PublicIpAddress" --output text
curl "http://${IP}/health"; curl "http://${IP}/v1/client/orders?id=1001"

# 모듈3 (Inbound 0개여야 함)
aws ec2 describe-security-groups --region ap-southeast-1 --filters "Name=tag:Name,Values=skills-ceh-protected-sg" --query "SecurityGroups[].IpPermissions" --output json

# 모듈4 — 스케일아웃 실증은 bastion 세션에서 (아래 bash 블록)
```

```bash
# 모듈4 스케일아웃 실증 — bastion SSM 세션 안에서 실행
QUEUE_URL=$(aws sqs get-queue-url --region us-west-2 --queue-name skills-sqs-queue --query QueueUrl --output text)
for i in $(seq 1 12); do aws sqs send-message --region us-west-2 --queue-url "$QUEUE_URL" --message-body "judge-$i"; done
watch -n5 'kubectl get pods -n skills-sqs -l app=sqs-worker -o wide; kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool'
```

---

## 트러블슈팅

대부분 bastion에서 자동 처리되지만, 직접 확인/재실행할 때 참고.

### ① bastion이 K8s 배포를 끝냈는지 확인
```powershell
$BASTION = terraform output -raw bastion_instance_id
aws ssm start-session --target $BASTION --region us-west-2
```
```bash
# bastion 안에서
sudo tail -n 50 /var/log/skills-bastion-bootstrap.log   # "BASTION_BOOTSTRAP_DONE"?
cd /root/2026-terraform/07/2과제 && bash k8s-apply.sh    # 재실행(멱등)
```

### ② CoreDNS가 Fargate에 안 떠서 DNS 죽음 (`STS/SQS lookup ... 53: connection refused`)
EKS-Fargate 고질 문제. `k8s-apply.sh`가 **맨 앞에서 자동 패치**합니다(CoreDNS Pod의 `eks.amazonaws.com/compute-type: ec2` 어노테이션 제거). 수동으로 한다면 bastion에서:
```bash
kubectl patch deployment coredns -n kube-system --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]'
kubectl rollout restart deployment coredns -n kube-system
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide   # Fargate에서 Running 확인
```

### ③ `kubectl` 401 `the server has asked for the client to provide credentials`
bastion role(`skills-sqs-bastion-role`)은 `module4.tf`에서 EKS admin access entry로 자동 등록됩니다. **Windows에서 직접** kubectl을 쓰고 싶으면 본인 주체도 등록:
```powershell
$PRINCIPAL = aws sts get-caller-identity --query Arn --output text
aws eks create-access-entry --region us-west-2 --cluster-name skills-sqs-cluster --principal-arn $PRINCIPAL
aws eks associate-access-policy --region us-west-2 --cluster-name skills-sqs-cluster `
  --principal-arn $PRINCIPAL `
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
```
> `module4.tf`의 `aws_eks_access_entry.m4_admin`도 apply 실행 주체를 자동 등록하지만, Windows에 kubectl이 없으면 의미 없으니 보통 bastion으로 작업합니다.

### ④ Karpenter `1/2` (비리더 replica CrashLoop)
`k8s-apply.sh`에서 `--set replicas=1`로 단일 리더 운영. 이미 떠 있으면:
```bash
kubectl scale deployment karpenter -n karpenter --replicas=1
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
├── module4.tf       # EKS+SQS+IRSA (us-west-2) + Bastion EC2
├── app/             # 앱 소스 (제공 배포파일 그대로)
├── k8s-apply.sh     # 모듈4 K8s 배포 — bastion이 자동 실행(어디서든 실행 가능, terraform state 불필요)
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
| Bastion 인스턴스 타입 | `module4.tf` | `aws_instance.m4_bastion` → `instance_type` | `t3.small` |
| Bastion이 clone하는 repo | `module4.tf` | `aws_instance.m4_bastion` user_data의 `git clone` URL | `hnmly/2026-terraform` |
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
- 모듈4 리전 변경 시 `module4.tf`의 `aws_ec2_tag`·서브넷 태그(`kubernetes.io/cluster/...`)·**bastion user_data 안의 `REGION=us-west-2`**, `k8s-apply.sh` 상단 `REGION=`, 모듈1 user_data의 리전도 함께 확인

### 비번호가 필요한 리소스 (Global Unique)

- 모듈3 CloudTrail S3 버킷: `module3.tf` → `aws_s3_bucket.m3_trail` → `bucket_prefix = "skills-ceh-trail-"`
  - 비번호 지정 시: `bucket = "skills-ceh-trail-<비번호>"` 로 변경
