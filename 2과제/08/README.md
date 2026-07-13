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

# 소스: 지급된 2과제 폴더로 이동 (별도 clone 불필요 — 런타임 외부 repo 의존 없음)
cd C:\Users\competitor\2026-terraform\2과제\08
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

> **재실행이 필요하면** bastion에서 (앱·스크립트가 인스턴스에 내장되어 외부 repo 불필요):
> ```bash
> cd /root/task2 && bash k8s-apply.sh
> ```

---

## (선택) 옵션 B — Linux 배포용 bastion에서 루트 전체 apply

멀티 리전 apply를 Windows에서 직접 돌리기 어려운 경우, `bastion/` 폴더를 로컬에서
apply하면 **배포 전용 Linux bastion**(전용 VPC `10.250.0.0/16`, SSM 접속)이 생성되고,
로컬 2과제 코드가 S3 번들로 업로드되어 `/opt/task2`에 준비됩니다. 이후 그 안에서
루트 전체(module1~4 + in-VPC bastion)를 한 번에 apply 합니다.

```powershell
# 1) 로컬(Windows)에서 배포용 bastion 생성
cd C:\Users\competitor\2026-terraform\2과제\08\bastion
terraform init
terraform apply -auto-approve
terraform output ssm_connect_command      # 접속 명령 출력

# 2) SSM 접속 (키페어 불필요)
aws ssm start-session --target <bastion-instance-id> --region us-west-2
```
```bash
# 3) bastion 안에서: 부트스트랩 완료 대기 후 원클릭 실행
until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done
bash /opt/task2/run.sh      # = terraform init && apply (루트 전체)
```
> 채점 직전 로컬에서 `cd bastion; terraform destroy` 로 **배포용 bastion만** 제거합니다
> (채점 대상 리소스는 유지). 두 bastion의 state는 서로 분리되어 있습니다.

### 로컬 apply vs bastion 요약
| 모듈 | 로컬(Windows) 단독 apply | 비고 |
|------|--------------------------|------|
| 1 DocumentDB | ✅ 생성됨 | EC2 user_data가 앱 설치·seed·인덱스까지 자동(AWS 내부 실행) |
| 2 VPC Lattice | ✅ 생성됨 | EC2 user_data가 앱 자동 기동(AWS 내부 실행) |
| 3 Cloud Event Handling | ✅ 생성됨 | 순수 리소스(부트스트랩 없음) — Windows에서 그대로 완성 |
| 4 EKS/SQS | ✅ 생성됨 | EKS+in-VPC bastion까지 생성, bastion이 K8s 레이어 자동 배포 |
> 4개 모듈 모두 **로컬 `terraform apply` 한 번으로 완성**됩니다. 옵션 B는 Windows에서
> 멀티리전 apply가 불편할 때의 대안일 뿐, 결과물은 동일합니다.

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
cd /root/task2 && bash k8s-apply.sh    # 재실행(멱등, 외부 repo 불필요)
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
├── module1.tf       # DocumentDB (ap-northeast-2)  — EC2 user_data는 app/module1/userdata.sh.tpl
├── module2.tf       # VPC Lattice (ap-northeast-1)
├── module3.tf       # EventBridge+Lambda (ap-southeast-1)
├── module4.tf       # EKS+SQS+IRSA (us-west-2) + in-VPC Bastion EC2(app/module4/bastion-userdata.sh.tpl)
├── app/             # 앱 소스 (제공 배포파일 그대로) + user_data 템플릿(.tpl)
│   ├── module1/     # docdb_client.py, retail_dataset.json, requirements.txt, userdata.sh.tpl
│   ├── module2/     # client/service 앱 + userdata 스크립트(인라인 heredoc)
│   ├── module3/     # remediate_security_group.py (Lambda)
│   └── module4/     # worker.py, Dockerfile, requirements.txt, bastion-userdata.sh.tpl
├── k8s-apply.sh     # 모듈4 K8s 배포 — in-VPC bastion이 자동 실행(state 불필요, 멱등)
├── bastion/         # (선택) 로컬 대신 Linux bastion에서 루트 전체를 apply 하는 STAGE1 폴더
└── README.md
```

> **자체 완결(self-contained)**: 모든 EC2/bastion 부트스트랩은 앱 소스를 terraform이
> `base64gzip`으로 user_data에 인라인 주입한다. 런타임에 GitHub 등 외부 저장소를
> 내려받지 않으므로, 어디서(로컬 Windows / bastion) apply 하든 동일하게 동작한다.

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
| Bastion K8s 부트스트랩 스크립트 | `app/module4/bastion-userdata.sh.tpl` (`k8s-apply.sh`+worker 앱을 base64gzip 인라인 주입, 외부 repo clone 없음) | 템플릿 편집 | — |
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


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\2과제\08\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.
