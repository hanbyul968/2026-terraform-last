# 제2과제 — Small Challenges (실행 가이드)

> 기준 문서: `과제지_vf.pdf` / `채점기준표_vf.pdf` (제61회 인천기능경기대회 · 클라우드컴퓨팅 2과제)
> 서로 독립된 **4개 모듈**로 구성되며, 각 모듈은 지정된 리전에 고정 리소스 이름으로 생성합니다.

| 모듈 | 주제 | 리전 | 배점 |
|------|------|------|------|
| 1 | DocumentDB based NoSQL Application | ap-northeast-2 (서울) | 7.5 |
| 2 | Simplify Service Networking with VPC Lattice | ap-northeast-1 (도쿄) | 7.5 |
| 3 | Cloud Event Handling | ap-southeast-1 (싱가포르) | 7.5 |
| 4 | Event-driven Pod Scaling with AWS SQS | us-west-2 (오레곤) | 7.5 |
| | **합계** | | **30** |

> **핵심 설계**: `terraform apply` **한 번**으로 4개 리전 인프라 전부 + 오레곤 in-VPC **bastion EC2**까지 생성됩니다.
> 모듈4 bastion 이 부팅하면서 **CoreDNS(Fargate) 패치 → KEDA/Karpenter 설치 → Worker 이미지 build/push → K8s 리소스 apply**(`k8s-apply.sh`)를 자동 실행합니다.
> 모든 앱 소스는 terraform 이 `base64gzip` 으로 user_data 에 인라인 주입 → 런타임에 외부 저장소(GitHub 등) 의존 없음(self-contained). Windows/CloudShell/bastion 어디서 apply 해도 동일하게 동작.

---

## 0. 준비 (Windows / PowerShell)

```powershell
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI

aws configure        # 대회 지급 계정 Access Key / Secret / region=us-west-2

cd C:\Users\competitor\2026-terraform\2과제\08
```

> ⚠️ 리소스 이름·태그·환경변수는 **대소문자를 구분**하며, 리전이 틀리면 해당 모듈은 0점입니다.
> `skills-*` 고정 이름은 절대 변경하지 마세요.

---

## 1. 배포 — 두 방법 중 택1

### 방법 A (권장) — 로컬에서 바로 apply

```powershell
cd C:\Users\competitor\2026-terraform\2과제\08
terraform init
terraform apply -var="docdb_password=Skills2026!" -auto-approve
```

한 번의 apply 로 아래가 전부 생성됩니다. ⏱ EKS + bastion 부트스트랩 포함 ~25분.

- **모듈1** — DocumentDB Cluster/Instance + KMS + Secret + Client EC2(앱 자동 설치·seed·인덱스/TTL 생성)
- **모듈2** — Client/Service VPC + Client/Service EC2(앱 자동 기동) + VPC Lattice(SN/Service/TG/Listener)
- **모듈3** — VPC/EC2 + 보호 SG + SNS + Lambda + CloudTrail + EventBridge Rule
- **모듈4** — VPC + EKS + Fargate Profile + SQS + IRSA Role + **in-VPC bastion EC2**

**모듈4 bastion 이 자동으로 하는 일** (user_data → `k8s-apply.sh`):
채점자 IAM User EKS access entry 등록 → CoreDNS 를 Fargate 로 패치 → Worker 이미지 ECR build/push → 서브넷 태깅 → KEDA/Karpenter Helm 설치(`--wait`) → `sqs-worker` SA/Deployment → KEDA `TriggerAuthentication`(`podIdentity.provider: aws-eks`)/`ScaledObject` → Karpenter `EC2NodeClass`/`NodePool`.

> terraform 인프라 apply 는 먼저 끝나고, bastion 의 K8s 배포는 **백그라운드로 수 분** 더 걸립니다. 완료 확인은 **2장** 참고.

### 방법 B — Linux 배포 bastion 경유 (멀티리전 apply 가 불편할 때)

```powershell
cd C:\Users\competitor\2026-terraform\2과제\08\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command    # 접속 명령 확인
```

전용 VPC `10.250.0.0/16` 의 **STAGE1 배포 bastion**(SSM 접속, 키페어 불필요)이 생성되고, 로컬 코드가 S3 번들로 `/opt/task2` 에 준비됩니다.

```powershell
aws ssm start-session --target <bastion-instance-id> --region us-west-2
```
```bash
# STAGE1 bastion 안에서:
until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done   # 준비 완료 대기(2~3분)
bash /opt/task2/run.sh          # 루트 전체 apply (= 방법 A 를 bastion 에서 실행)
```

> `run.sh` 가 끝나면 방법 A 와 동일하게 **모듈4 in-VPC bastion** 이 이어서 생성되어 K8s 배포를 자동 수행합니다. 진행 확인은 2장 참고.

---

## 2. 진행상황 확인 (bastion 로그) — ★ 로그 파일 이름 주의

bastion 은 인바운드 없이 **SSM** 으로만 접속합니다(키페어 불필요).
**어느 bastion 에 접속했는지에 따라 로그 파일 이름이 다릅니다.** (접속 IP 대역으로 구분)

| bastion | VPC 대역 | 로그 파일 | 완료 마커 |
|---|---|---|---|
| **모듈4 in-VPC bastion** (실제 K8s 배포 수행 · 방법 A·B 공통) | `10.4.0.0/16` | `/var/log/skills-bastion-bootstrap.log` | `BASTION_BOOTSTRAP_DONE` |
| **STAGE1 배포 bastion** (방법 B 에서만) | `10.250.0.0/16` | `/var/log/bastion-bootstrap.log` | `/opt/task2/READY` |

### (A) 모듈4 in-VPC bastion — K8s 배포 로그 확인

```powershell
# 방법 A 는 루트(08)에서, 방법 B 는 STAGE1 bastion 의 /opt/task2 에서 실행
$BASTION = terraform output -raw bastion_instance_id
aws ssm start-session --target $BASTION --region us-west-2
```
```bash
# 세션 안에서 — 마지막에 "BASTION_BOOTSTRAP_DONE" 나오면 완료
sudo tail -f /var/log/skills-bastion-bootstrap.log

# 완료 후 검증 (kubectl/helm 이미 설치·인증됨)
kubectl get pod -n keda
kubectl get pod -n karpenter
kubectl get deploy sqs-worker -n skills-sqs
```
> 재실행이 필요하면 (멱등, 외부 repo 불필요): `cd /root/task2 && bash k8s-apply.sh`

### (B) STAGE1 배포 bastion (방법 B, IP 가 `10.250.x` 인 경우)

이 bastion 에는 `skills-bastion-bootstrap.log` 가 **없습니다**(그건 모듈4 bastion 로그). 여기선:
```bash
sudo tail -f /var/log/bastion-bootstrap.log        # 이 bastion 의 부트스트랩 로그
until [ -f /opt/task2/READY ]; do sleep 5; done     # READY 대기
bash /opt/task2/run.sh                              # 루트 apply → 모듈4 bastion 생성
```
`run.sh` 완료 후 위 (A) 절차로 모듈4 bastion 에 접속해 `skills-bastion-bootstrap.log` 를 확인합니다.

---

## 3. 채점 기준 검증 (CloudShell 기준)

채점은 CloudShell 자동화 스크립트로 진행됩니다. 아래는 채점기준표의 실제 확인 명령입니다.

### 모듈1 — DocumentDB (ap-northeast-2)

```bash
IP=$(aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# 1-1 Cluster/Instance/KMS
aws docdb describe-db-clusters  --region ap-northeast-2 --db-cluster-identifier  skills-nosql-docdb-cluster   --output table
aws docdb describe-db-instances --region ap-northeast-2 --db-instance-identifier skills-nosql-docdb-instance-1 --output table
aws kms describe-key --region ap-northeast-2 --key-id alias/skills-nosql-docdb --output table
# 1-2 Secret(username/password/host) + Client EC2 running/PublicIP
aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id skills-nosql-docdb-secret --query SecretString --output text
# 1-3 앱 + 데이터 적재  / 1-4 Index·TTL  / 1-5 조회 API
curl -s "http://$IP:8080/health"; curl -s "http://$IP:8080/v1/admin/summary"
curl -s "http://$IP:8080/v1/admin/indexes"
curl -s "http://$IP:8080/v1/orders/O-1001"
curl -s "http://$IP:8080/v1/customers/C001/orders"
curl -s "http://$IP:8080/v1/orders/pending?from=2026-06-01T00:00:00Z&to=2026-06-08T00:00:00Z"
curl -s "http://$IP:8080/v1/products/low-stock?warehouseId=W-A"
```

### 모듈2 — VPC Lattice (ap-northeast-1)

```bash
IP=$(aws ec2 describe-instances --region ap-northeast-1 \
  --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# 2-1 VPC CIDR 10.61/10.62  2-2 EC2/health  2-3 SN/Service/Assoc ACTIVE  2-4 TG/Listener/SG
aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-vpc,skills-lattice-service-vpc --output table
curl -s "http://$IP/health"
# 2-5 End-to-End: order_id=1001, via=vpc-lattice 포함
curl -s "http://$IP/v1/client/orders?id=1001"
```
> Service EC2 SG 는 **TCP/8080 을 VPC Lattice Managed Prefix List 소스만** 허용합니다(0.0.0.0/0 허용 시 미충족).

### 모듈3 — Cloud Event Handling (ap-southeast-1)

```bash
# 3-2 보호 SG Inbound 0개
aws ec2 describe-security-groups --region ap-southeast-1 \
  --filters Name=tag:Name,Values=skills-ceh-protected-sg --query "SecurityGroups[].IpPermissions" --output json
# 3-3 SNS/Lambda(runtime python3.12 / handler / timeout>=30 / env)
aws lambda get-function-configuration --region ap-southeast-1 --function-name skills-ceh-remediate-fn --output table
# 3-4 CloudTrail logging / EventBridge Rule / Target / Lambda Resource Policy
aws cloudtrail get-trail-status --region ap-southeast-1 --name skills-ceh-cloudtrail --output table
aws lambda get-policy --region ap-southeast-1 --function-name skills-ceh-remediate-fn --query Policy --output text

# 3-5 기능검증: 임시 Inbound 추가 → Lambda 호출 → 180초 내 0개 복구 + 로그 생성
SG=$(aws ec2 describe-security-groups --region ap-southeast-1 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --region ap-southeast-1 --group-id "$SG" --protocol tcp --port 22 --cidr 0.0.0.0/0
jq -n --arg sg "$SG" '{detail:{eventName:"AuthorizeSecurityGroupIngress",requestParameters:{groupId:$sg}}}' > /tmp/ev.json
aws lambda invoke --region ap-southeast-1 --function-name skills-ceh-remediate-fn \
  --cli-binary-format raw-in-base64-out --payload file:///tmp/ev.json /tmp/out.json
aws ec2 describe-security-groups --region ap-southeast-1 --group-ids "$SG" --query "SecurityGroups[0].IpPermissions" --output json
```
> 3-4 는 EventBridge → Lambda **리소스 기반 정책**(`get-policy`)까지 확인합니다. 콘솔에서 규칙 대상만 지정하면 자동 추가 안 될 수 있으니, 없으면 `aws lambda add-permission --principal events.amazonaws.com --source-arn <rule-arn> ...` 로 부여.

### 모듈4 — SQS Scaling (us-west-2)

```bash
aws eks update-kubeconfig --region us-west-2 --name skills-sqs-cluster
QUEUE_URL=$(aws sqs get-queue-url --region us-west-2 --queue-name skills-sqs-queue --query QueueUrl --output text)

# 4-1 Cluster/Fargate  4-2 SQS/IRSA SA  4-3 KEDA·Karpenter Pod  4-4 Worker/ScaledObject  4-5 NodePool/EC2NodeClass
kubectl get serviceaccount keda-operator -n keda -o yaml
kubectl get serviceaccount karpenter -n karpenter -o yaml
kubectl get serviceaccount sqs-worker-sa -n skills-sqs -o yaml
kubectl get scaledobject sqs-worker-scaledobject -n skills-sqs -o yaml
kubectl get nodepool skills-sqs-nodepool -o yaml

# 4-6 Scale Out: 12개 발행 → 180초 내 Worker Pod / Karpenter EC2 Node 증가 + Queue depth 감소
for i in $(seq 1 12); do aws sqs send-message --region us-west-2 --queue-url "$QUEUE_URL" --message-body "judge-$i"; done
kubectl get pods -n skills-sqs -l app=sqs-worker -o wide
kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool,skills-nodepool=event-worker -o wide
```
> **4-5 팁**: NodePool/EC2NodeClass 는 상시 존재하지만 "Worker EC2 Node·Worker Pod 배치" 는 유휴(min 0) 상태에서 비어 보입니다. 확실히 하려면 **4-6 부하를 준 상태**에서 4-5 의 `get nodes -l ...` / `get pods -n skills-sqs` 를 실행하세요.

---

## 4. 모듈별 요구사항 ↔ 구현 매핑

### 모듈1 (`module1.tf`, `app/module1/`)
- VPC `10.1.0.0/16` — Public 서브넷(Client EC2, Public IP) + Private 서브넷 2개(DocDB, 외부 미노출)
- DocumentDB: Cluster `skills-nosql-docdb-cluster`, Instance `skills-nosql-docdb-instance-1`, `db.t3.medium`, **Storage 암호화 + KMS `alias/skills-nosql-docdb`**, **TLS enabled**(cluster param group), **Backup 보존 1일 이상**
- Secret `skills-nosql-docdb-secret`: `username` / `password` / `host`(**엔드포인트 호스트명만**, scheme·port 미포함 → `aws_docdb_cluster.endpoint`)
- Client EC2 `skills-nosql-client-ec2`: 제공 `docdb_client.py` 무수정 배포, `0.0.0.0:8080`, boot 시 seed + Index/TTL 자동 생성
  - DB `skills_retail` · orders≥8/products≥6/sessions≥3 · orders `{orderId}unique / {customerId,createdAt:-1} / {status,dueAt}` · products `{productId}unique / {warehouseId,stock}` · sessions `{sessionId}unique / {expiresAt}TTL0 / {customerId,lastSeen:-1}`

### 모듈2 (`module2.tf`, `app/module2/`)
- Client VPC `10.61.0.0/16` / Service VPC `10.62.0.0/16` (Peering·TGW 없음)
- Client EC2 `skills-lattice-client-ec2`: 제공 `client_app.py`, TCP/80, Public 접근, `SERVICE_URL`=Lattice Generated Domain 자동 조회, SG 80 from 0.0.0.0/0
- Service EC2 `skills-lattice-service-ec2`: 제공 `service_app.py`, TCP/8080, **Public IP 없음**, SG 8080 **Lattice Managed Prefix List 소스만**(stdlib 앱이라 아웃바운드 인터넷 불필요)
- Lattice: SN `skills-lattice-sn`(VPC Association SG 80 from `10.61.0.0/16`), Service `skills-lattice-order-service`, TG `skills-lattice-order-tg`(INSTANCE/HTTP/8080/health `/health`), Listener `skills-lattice-http-listener`(HTTP/80 → TG forward)

### 모듈3 (`module3.tf`, `app/module3/`)
- VPC `10.73.0.0/16`, EC2 `skills-ceh-ec2`, 보호 SG `skills-ceh-protected-sg`(**최종 Inbound 0개**)
- SNS `skills-ceh-alert-topic`(Standard)
- Lambda `skills-ceh-remediate-fn`: 제공 `remediate_security_group.py`, **Python 3.12 / handler `remediate_security_group.lambda_handler` / timeout 30초**, env `PROTECTED_SECURITY_GROUP_ID`·`SNS_TOPIC_ARN`, IAM(SG 조회·수정 / SNS Publish / Logs) → Inbound 전량 revoke + SNS 발행 + 로그 기록
- CloudTrail `skills-ceh-cloudtrail`(**enable_logging=true, 관리 이벤트 명시 로깅**) + EventBridge Rule `skills-ceh-sg-change-rule`(default bus, `AuthorizeSecurityGroupIngress` 패턴, Target=Lambda, **Lambda resource policy 로 events.amazonaws.com invoke 허용**)

### 모듈4 (`module4.tf`, `k8s-apply.sh`, `app/module4/`)
- VPC `10.4.0.0/16`(Public/Private 각 2 AZ, NAT) — EKS `skills-sqs-cluster`(**Public Endpoint** → CloudShell kubectl 접근)
- Fargate Profile `skills-sqs-fp-keda`(ns keda) / `skills-sqs-fp-karpenter`(ns karpenter) (+ kube-system for CoreDNS)
- SQS `skills-sqs-queue`(Standard, **Visibility 60초** ≥30)
- IRSA: `keda/keda-operator`, `karpenter/karpenter`, `skills-sqs/sqs-worker-sa` (SA 에 `eks.amazonaws.com/role-arn` annotation)
- Worker: 제공 `worker.py`+`boto3` 이미지, ns `skills-sqs` / Deploy `sqs-worker` / SA `sqs-worker-sa`, label `app=sqs-worker`, env `SQS_QUEUE_URL/AWS_REGION/PROCESSING_SECONDS=5`, nodeSelector `karpenter.sh/nodepool=skills-sqs-nodepool` + `skills-nodepool=event-worker` (**Fargate 아닌 Karpenter EC2 노드에서 실행**)
- KEDA: `sqs-worker-scaledobject` / `sqs-worker-trigger-auth`, trigger `aws-sqs-queue` **queueLength 2, min 0, max 6, pollingInterval 15, cooldownPeriod 30**
- Karpenter: NodePool `skills-sqs-nodepool`(label `skills-nodepool=event-worker`, `disruption.consolidationPolicy` 포함) / EC2NodeClass `skills-sqs-nodeclass`

---

## 5. 파일 구조

```
2과제/08/
├── provider.tf        # aws alias 4개(seoul/tokyo/singapore/oregon) + tls/null/archive
├── variables.tf       # docdb_password
├── module1.tf         # DocumentDB (ap-northeast-2)  — EC2 user_data: app/module1/userdata.sh.tpl
├── module2.tf         # VPC Lattice (ap-northeast-1) — client/service EC2 userdata
├── module3.tf         # SNS/Lambda/CloudTrail/EventBridge (ap-southeast-1)
├── module4.tf         # EKS/Fargate/SQS/IRSA (us-west-2) + in-VPC Bastion EC2
├── k8s-apply.sh       # 모듈4 K8s 배포 — bastion 이 자동 실행(state 불필요, 멱등)
├── app/
│   ├── module1/       # docdb_client.py, retail_dataset.json, requirements.txt, userdata.sh.tpl
│   ├── module2/       # client/ + service/ 앱 + userdata 스크립트
│   ├── module3/       # remediate_security_group.py (Lambda)
│   └── module4/       # worker.py, Dockerfile, requirements.txt, bastion-userdata.sh.tpl
├── bastion/           # (선택) 로컬 대신 Linux bastion 에서 루트 전체를 apply 하는 STAGE1
└── README.md
```

> **자체 완결(self-contained)**: EC2/bastion 부트스트랩은 앱 소스를 terraform 이 `base64gzip` 으로 user_data 에 인라인 주입한다. 런타임에 외부 저장소를 내려받지 않으므로 apply 위치와 무관하게 동일하게 동작한다.

---

## 6. 트러블슈팅

**① CoreDNS 가 Fargate 에 안 떠 DNS 실패 (`... :53: connection refused`)**
EKS-Fargate 고질 이슈. `k8s-apply.sh` 가 맨 앞에서 자동 패치(CoreDNS 의 `eks.amazonaws.com/compute-type: ec2` 어노테이션 제거). 수동:
```bash
kubectl patch deployment coredns -n kube-system --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]'
kubectl rollout restart deployment coredns -n kube-system
```

**② `kubectl` 401 (credentials)** — bastion role 은 `module4.tf` 에서 EKS admin access entry 로 자동 등록됩니다. Windows/CloudShell 에서 직접 쓰려면 본인 주체 등록:
```bash
PRINCIPAL=$(aws sts get-caller-identity --query Arn --output text)
aws eks create-access-entry --region us-west-2 --cluster-name skills-sqs-cluster --principal-arn "$PRINCIPAL"
aws eks associate-access-policy --region us-west-2 --cluster-name skills-sqs-cluster \
  --principal-arn "$PRINCIPAL" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
```

**③ Karpenter `1/2` (비리더 replica CrashLoop)** — `k8s-apply.sh` 는 `--set replicas=1` 로 단일 리더 운영. 이미 떠 있으면 `kubectl scale deployment karpenter -n karpenter --replicas=1`.

**④ Worker Pod 가 Fargate 로 스케줄됨** — `skills-sqs` 네임스페이스에는 Fargate Profile 이 없어야 하며, nodeSelector 로 Karpenter EC2 노드에만 스케줄됩니다.

**⑤ `skills-bastion-bootstrap.log` 가 없다 (`No such file or directory`)** — 접속한 bastion 을 잘못 본 것입니다(2장 표 참고).
- 접속 IP 가 `10.250.x` = **STAGE1 배포 bastion** → 로그는 `/var/log/bastion-bootstrap.log`. `skills-*` 로그는 아직 없음 → `/opt/task2/READY` 대기 후 `bash /opt/task2/run.sh` 로 **모듈4 bastion** 을 먼저 생성해야 함.
- 접속 IP 가 `10.4.x` = **모듈4 bastion** → 여기서만 `/var/log/skills-bastion-bootstrap.log` 존재. 부팅 직후라면 아직 파일 생성 전일 수 있으니 잠시 후 재시도(또는 `sudo tail -f /var/log/cloud-init-output.log`).

---

## 7. 대회 당일 변경 대응 (최대 30% 변경 상정)

`skills-*` 고정 이름은 유지. 값만 아래 위치에서 수정합니다.

### 리전 변경 — `provider.tf` 의 해당 alias `region`
| 모듈 | alias | 현재 리전 |
|------|-------|-----------|
| 1 | `seoul` | ap-northeast-2 |
| 2 | `tokyo` | ap-northeast-1 |
| 3 | `singapore` | ap-southeast-1 |
| 4 | `oregon` | us-west-2 |
> 추가: 모듈2 리전 변경 시 `module2.tf` 의 `data.aws_ec2_managed_prefix_list.lattice` → `name = "com.amazonaws.<NEW_REGION>.vpc-lattice"`.
> 모듈4 리전 변경 시 `k8s-apply.sh`·`app/module4/bastion-userdata.sh.tpl` 상단 `REGION=`, 서브넷/`aws_ec2_tag` 태그도 함께 확인.

### 모듈1 — `module1.tf` / `variables.tf`
VPC/서브넷 CIDR(`aws_vpc.m1`, `aws_subnet.m1_public/private`), DocDB 인스턴스 클래스(`aws_docdb_cluster_instance.m1`), master 계정(`aws_docdb_cluster.m1` + Secret `username`), 비밀번호(`variables.tf` 또는 `-var`), backup 보존(`backup_retention_period`), Client 포트(`aws_security_group.m1_ec2` = 8080).

### 모듈2 — `module2.tf`
Client/Service VPC·서브넷 CIDR, **Client VPC CIDR 변경 시 `aws_security_group.m2_lattice_assoc.ingress.cidr_blocks` 도 동시 수정**, Service 포트(SG + TG `config.port` + attachment `target.port` 세 곳 = 8080), Client 포트(SG + Listener `port` 두 곳 = 80).

### 모듈3 — `module3.tf`
VPC/서브넷 CIDR, Lambda runtime(`python3.12`)/timeout(`30`). CloudTrail S3 버킷은 Global Unique → 비번호 지정 시 `aws_s3_bucket.m3_trail` 를 `bucket = "skills-ceh-trail-<비번호>"` 로.

### 모듈4 — `module4.tf` + `k8s-apply.sh`
VPC/서브넷 CIDR, SQS Visibility(`aws_sqs_queue.m4` = 60), Bastion 인스턴스 타입. K8s 파라미터는 `k8s-apply.sh`: KEDA `queueLength "2"`/`pollingInterval 15`/`cooldownPeriod 30`/`maxReplicaCount 6`, NodePool instance-type/`consolidateAfter 30s`, Worker `PROCESSING_SECONDS "5"`, KEDA `--version 2.20.2`, Karpenter `--version 1.11.3` (EKS `version = "1.34"` 와 한 쌍으로 관리).

---

## 8. Bastion 네트워크 & 정리

- **모듈4 in-VPC bastion**: 모듈4 VPC(`10.4.0.0/16`) 안에 생성, K8s 배포 수행. SSM 접속, 로그 `/var/log/skills-bastion-bootstrap.log`.
- **STAGE1 배포 bastion**(방법 B): 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 + IGW. (이 계정엔 default VPC 가 없어 자체 VPC 생성. 접속은 SSM 아웃바운드 443 만 사용.) 로그 `/var/log/bastion-bootstrap.log`.
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`) — minimal AMI 는 SSM 에이전트 없어 제외.
- **삭제**:
```powershell
# 방법 B 로 만든 STAGE1 배포 bastion 만 제거 (채점 대상 리소스와 state 분리)
cd C:\Users\competitor\2026-terraform\2과제\08\bastion
terraform destroy -auto-approve
```
> ⚠️ 경기 종료 후 채점·이의신청 완료 전까지 생성 리소스를 삭제/수정하지 마세요.
