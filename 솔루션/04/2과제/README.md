# 🖥️ 제2과제 (인천 v4) — AWS 콘솔 풀이 가이드

> **Small challenge · 4시간 · 배점 30점** — Terraform 없이 **AWS Management Console + Bastion 터미널**만으로
> 4개 모듈을 처음부터 끝까지 구성하는 문서.
> 각 단계는 **① 입력값 표 → ② 클릭 순서 → ③ 채점 포인트 → ⚠️ 주의** 순서로 정리했다.

---

## 🧭 시작 전 3가지

| 항목 | 값 |
|---|---|
| **모듈마다 리전이 다르다** | 화면 우상단 리전을 **매번 확인**하고 바꾼다 |
| 이름/태그 | 표에 적힌 **대소문자·하이픈 그대로** (채점이 `Name` 태그로 찾음) |
| 부분점수 | **없음.** 한 항목이라도 틀리면 그 세부항목 0점 |

### 🌏 모듈별 리전 (제일 많이 틀리는 부분)

| 모듈 | 주제 | 리전 | 배점 |
|---|---|---|---|
| **1** | EKS Scaling (KEDA + Karpenter) | **ap-northeast-2** (서울) | 7.5 |
| **2** | VPC Lattice | **ap-southeast-1** (싱가포르) | 7.5 |
| **3** | Container Logging (Fluent Bit → Loki → Grafana) | **ap-northeast-1** (도쿄) | 7.5 |
| **4** | REST API Implement (API GW + Lambda + DynamoDB) | **us-east-1** (버지니아) | 7.5 |

### 🧾 채점 방식 요약 (채점기준표 13-3)

- **Bastion에서 채점** — `mark1.sh`(모듈1) · `mark2.sh`(모듈2) · `mark3.sh`(모듈3)
  → 각 모듈 Bastion의 `/home/ec2-user/marking/` 에 복사 후 실행. **ec2-user로 SSH 접속**
- **CloudShell에서 채점** — `mark4.sh`(모듈4) → `/home/cloudshell-user/marking/`
- ⚠️ **Bastion 접속(SSH)이 안 되면 그 모듈 전체가 0점.** 최우선으로 확보할 것.
- ⚠️ 모듈1·2·3 Bastion 모두 **awscli + kubectl + jq** 가 있어야 하고 **Admin 권한**이 필요하다.

---

## ✅ 전체 진행 체크리스트

```
── 모듈 1 : EKS Scaling (ap-northeast-2) ────────────────
[ ] 1.1  VPC wsc-scaling-vpc / 서브넷4 / IGW / NAT
[ ] 1.2  Bastion  wsc-scaling-bastion (EIP + Admin Role)
[ ] 1.3  SQS      wsc-scaling-sqs
[ ] 1.4  EKS      wsc-scaling-cluster (1.35)
[ ] 1.5  NodeGroup wsc-scaling-node (2/2/10, label dedicated=scaling)
[ ] 1.6  Namespace + Deployment wsc-scaling-deploy
[ ] 1.7  KEDA + ScaledObject wsc-scaling-scaledobject
[ ] 1.8  Karpenter + NodePool (cpu 100 / memory 200Gi)
[ ] 1.9  스케일링 테스트 (SQS 100건 → Pod 20 / Node 4)

── 모듈 2 : VPC Lattice (ap-southeast-1) ───────────────
[ ] 2.1  Hub VPC / Spoke VPC / IGW / NAT
[ ] 2.2  Bastion  wsc-hub-bastion (EIP, SSH 패스워드 Skill53##)
[ ] 2.3  App EC2  wsc-spoke-app-v1 / v2  (Flask :8080)
[ ] 2.4  ALB      wsc-spoke-app-alb (internal) + ELB TG 2개
[ ] 2.5  Lattice  Service Network + Service + TG 2개
[ ] 2.6  Lattice Listener Rule (default 90/10, header v1/v2)
[ ] 2.7  Hub Bastion에서 curl 테스트

── 모듈 3 : Container Logging (ap-northeast-1) ─────────
[ ] 3.1  VPC wsc-logging-vpc / 서브넷4
[ ] 3.2  EKS wsc-logging-cluster (1.35) + ng (2/2/4)
[ ] 3.3  EBS CSI Driver (PVC 10Gi 용)
[ ] 3.4  Loki    (Helm, SingleBinary, NLB:3100)
[ ] 3.5  Grafana (Helm, NLB, 대시보드 4패널)
[ ] 3.6  EC2 wsc-logging-app-bastion (Docker + SSM)
[ ] 3.7  Fluent Bit (systemd) → Loki
[ ] 3.8  E2E 테스트 (/generate → Grafana)

── 모듈 4 : REST API (us-east-1) ───────────────────────
[ ] 4.1  DynamoDB wsc-rest-table (PK name, On-demand)
[ ] 4.2  Lambda   wsc-rest-function (python3.14)
[ ] 4.3  API GW   wsc-rest-api  /v1/user (+Validator)
[ ] 4.4  /v1/healthcheck (MOCK)
[ ] 4.5  API Key  wsc-rest-api-key + Usage Plan
[ ] 4.6  prod 스테이지 배포 + curl 테스트
```

---

## 📌 공통 사전 지식

<details>
<summary><b>Bastion에 awscli v2 / kubectl / helm / jq 설치 (클릭)</b></summary>

Amazon Linux 2023 기준. Bastion 접속 후:

```bash
# jq / git
sudo dnf install -y jq git tar gzip

# awscli v2 (AL2023엔 이미 있음. 없으면)
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install --update

# kubectl (클러스터 1.35에 맞춤)
curl -sLO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl (Karpenter/KEDA IRSA 만들 때 편함)
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
  | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin/
```

</details>

<details>
<summary><b>Bastion에 SSH 패스워드 로그인 켜기 (모듈2 필수) (클릭)</b></summary>

```bash
sudo passwd ec2-user      # → Skill53## 두 번 입력
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
sudo systemctl restart sshd
```
> ⚠️ AL2023은 `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` 가 `no`로 덮어쓴다. **거기까지 고쳐야** 한다.
> User Data로 넣을 거면 위 3줄을 그대로 넣으면 된다.

</details>

<details>
<summary><b>Bastion용 Admin IAM Role 만들기 (클릭)</b></summary>

1. **IAM** → *Roles* → **Create role**
2. Trusted entity: **AWS service** → **EC2** → Next
3. Permissions: **AdministratorAccess** 체크 → Next
4. Role name: `wsc-bastion-role` → **Create role**
5. EC2 인스턴스 → *Actions → Security → Modify IAM role* 에서 붙인다.

> 모듈3의 Bastion(`wsc-logging-app-bastion`)은 채점 스크립트가 **SSM Send-Command**를 쓴다.
> → `AmazonSSMManagedInstanceCore` 도 반드시 함께 붙일 것. (AdministratorAccess 만으로는 SSM Agent 등록이 되지만, 명시적으로 붙이는 게 안전)

</details>

<details>
<summary><b>EKS 클러스터 접근 권한 (Access Entry) (클릭)</b></summary>

콘솔에서 EKS를 만들면 **만든 IAM 주체**만 kubectl이 된다. Bastion Role로도 붙여야 한다.

1. **EKS** → 클러스터 → *Access* 탭 → **Create access entry**
2. IAM principal: `wsc-bastion-role` 의 ARN
3. Access policy: **AmazonEKSClusterAdminPolicy** / Scope: **Cluster** → 생성

그 다음 Bastion에서:
```bash
aws eks update-kubeconfig --region <리전> --name <클러스터명>
kubectl get nodes
```

</details>

---
---

# 1️⃣ EKS Scaling — `ap-northeast-2`

> **목표**: SQS 메시지 수에 따라 **KEDA가 Pod를 늘리고**, Pod가 넘치면 **Karpenter가 Node를 늘린다**.
> 채점 마지막(1-6)에 SQS 메시지 100건을 넣고 **Pod 19~20개 / Node 4개**가 되는지 본다.

## 1.1 VPC 구성

**① 입력값**

| 리소스 | 이름 | 값 |
|---|---|---|
| VPC | `wsc-scaling-vpc` | `10.11.0.0/16` |
| 서브넷 | `wsc-scaling-sn-pub-a` | 10.11.0.0/24 · ap-northeast-2a · **public** |
| 서브넷 | `wsc-scaling-sn-pub-c` | 10.11.1.0/24 · ap-northeast-2c · **public** |
| 서브넷 | `wsc-scaling-sn-priv-a` | 10.11.10.0/24 · ap-northeast-2a · private |
| 서브넷 | `wsc-scaling-sn-priv-c` | 10.11.11.0/24 · ap-northeast-2c · private |

**② 클릭 순서** — *VPC → Create VPC → **VPC and more*** 로 한 번에 만드는 게 빠르다.

1. **VPC** → **Create VPC** → **VPC and more** 선택
2. Name tag auto-generation: `wsc-scaling` , IPv4 CIDR `10.11.0.0/16`
3. AZs **2** / Public subnets **2** / Private subnets **2**
4. **Customize subnets CIDR blocks** 눌러 위 표대로 입력
5. NAT gateways: **In 1 AZ** (비용/시간 절약. 2개도 무방)
6. VPC endpoints: **None**
7. DNS options: **Enable DNS hostnames** ✅ **Enable DNS resolution** ✅ → **Create VPC**
8. 생성 후 **Subnets** 에서 이름을 표대로 4개 정확히 수정
   (`wsc-scaling-subnet-public1-...` → `wsc-scaling-sn-pub-a`)
9. public 서브넷 2개 → *Edit subnet settings* → ✅ **Enable auto-assign public IPv4 address**

**③ 채점 포인트** — 1-1-A
```
wsc-scaling-sn-pub-a    ap-northeast-2a 10.11.0.0/24
wsc-scaling-sn-pub-c    ap-northeast-2c 10.11.1.0/24
wsc-scaling-sn-priv-a   ap-northeast-2a 10.11.10.0/24
wsc-scaling-sn-priv-c   ap-northeast-2c 10.11.11.0/24
```

> ⚠️ **AZ 매칭 주의**: `-a` 는 반드시 `ap-northeast-2a`, `-c` 는 `ap-northeast-2c`.
> *VPC and more* 마법사는 AZ를 알파벳순으로 배정하므로 2a/2b가 될 수 있다. **2b가 잡히면 직접 만든다.**

---

## 1.2 Bastion (`wsc-scaling-bastion`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Name | `wsc-scaling-bastion` |
| Type | **t3.medium** |
| AMI | Amazon Linux 2023 |
| Subnet | `wsc-scaling-sn-pub-a` (Public) |
| Public IP | **Elastic IP 로 고정** |
| IAM Role | `wsc-bastion-role` (AdministratorAccess) |

**② 클릭 순서**

1. **EC2** → *Launch instances*
2. Name `wsc-scaling-bastion` / AMI **Amazon Linux 2023** / Type **t3.medium**
3. Key pair 생성(`wsc-key.pem`) 후 다운로드 — **꼭 보관**
4. Network settings → *Edit*
   - VPC `wsc-scaling-vpc` / Subnet `wsc-scaling-sn-pub-a` / Auto-assign public IP **Enable**
   - SG 생성: 이름 `wsc-scaling-bastion-sg`
     - Inbound: **SSH 22 / 0.0.0.0/0**
     - Outbound: **All traffic / 0.0.0.0/0** (유의사항 2번 — 80/443 anyopen)
5. Advanced details → **IAM instance profile** = `wsc-bastion-role`
6. **Launch**
7. **EC2 → Elastic IPs → Allocate** → *Associate* → 이 인스턴스에 연결
   ⚠️ **재시작해도 IP가 안 변해야 한다** (과제지 명시). Auto-assign IP는 재시작하면 바뀌므로 **EIP 필수**.
8. SSH 접속 후 [공통 사전 지식]의 **awscli/kubectl/helm/jq/eksctl** 설치

**③ 채점 포인트** — 1-1-A `wsc-scaling-bastion  t3.medium`

---

## 1.3 SQS (`wsc-scaling-sqs`)

**② 클릭 순서**
1. **SQS** → **Create queue**
2. Type **Standard** / Name `wsc-scaling-sqs`
3. 나머지 **전부 기본값** (과제지: "명시되어 있지 않는 값은 모두 기본값")
4. **Create queue** → **URL 복사해서 메모장에 저장**

**③ 채점 포인트** — 1-1-A 마지막 줄 `wsc-scaling-sqs`

---

## 1.4 EKS 클러스터 (`wsc-scaling-cluster`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Name | `wsc-scaling-cluster` |
| Version | **1.35** |
| Subnets | **priv-a, priv-c, pub-a, pub-c** (4개 모두) |
| Endpoint access | Public and private |

**② 클릭 순서**

1. **EKS** → **Create cluster** → **Custom configuration** (Quick 아님)
2. Name `wsc-scaling-cluster` / Kubernetes version **1.35**
3. Cluster IAM role → *Create recommended role* (`AmazonEKSClusterPolicy`)
4. Cluster access → **EKS API and ConfigMap** / **Allow cluster administrator access** ✅
5. Networking → VPC `wsc-scaling-vpc` / Subnets **4개 전부** 선택
6. Cluster endpoint access: **Public and private**
7. Add-ons: `CoreDNS`, `kube-proxy`, `Amazon VPC CNI`, **`Node monitoring agent`** (기본값 그대로)
8. **Create** → **약 10분 소요** ⏳ (그 사이 모듈 2 인프라를 만들면 시간이 절약된다)

**③ 채점 포인트** — 1-2-A
```
wsc-scaling-cluster    1.35
```

---

## 1.5 Managed NodeGroup (`wsc-scaling-node`)

**① 입력값**

| 항목 | 값 |
|---|---|
| NodeGroup Name | `wsc-scaling-node` |
| Instance type | **t3.medium** |
| Min / Desired / Max | **2 / 2 / 10** |
| Labels | `dedicated` = `scaling` |
| Subnets | `wsc-scaling-sn-priv-a`, `wsc-scaling-sn-priv-c` |
| Node **Name 태그** | `wsc-scaling-node` |

**② 클릭 순서**

1. Node IAM Role 먼저 만들기 — **IAM → Create role → EC2**
   정책 4개: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`,
   `AmazonEKS_CNI_Policy`, **`AmazonSSMManagedInstanceCore`**
   → 이름 `wsc-scaling-node-role`
   > 💡 Karpenter가 만들 노드도 이 Role을 쓴다.
2. **EKS** → 클러스터 → *Compute* → **Add node group**
3. Name `wsc-scaling-node` / Role `wsc-scaling-node-role`
4. **Kubernetes labels** → **Add label** → Key `dedicated` / Value `scaling`
5. Next → AMI `Amazon Linux 2023 (AL2023_x86_64_STANDARD)` / Type **t3.medium**
6. Scaling: **Minimum 2 / Desired 2 / Maximum 10**
7. Subnets: **private 2개만** 선택
8. **Create** (약 3분)

**③ 채점 포인트** — 1-3-A
```
t3.medium       wsc-scaling-node
2      ← desired
2      ← min
10     ← max
scaling
```
> ⚠️ `scalingConfig` 출력을 `sort -n` 하므로 **desired=2, min=2, max=10** 이어야 `2 / 2 / 10` 이 나온다.
> Desired를 3으로 두면 `2 3 10` 이 되어 **0점**.

**④ Bastion에서 kubeconfig 연결**

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name wsc-scaling-cluster
kubectl get nodes
```
> 권한 에러가 나면 [공통 사전 지식 → Access Entry] 로 `wsc-bastion-role` 을 등록한다.

---

## 1.6 Namespace + Deployment

**① 입력값**

| 항목 | 값 |
|---|---|
| Namespace | `wsc-scaling` |
| Deployment | `wsc-scaling-deploy` |
| Image | `busybox:latest` |
| Command | `sleep` |
| Labels | `dedicated: scaling` |
| CPU | request `250m` / limit `500m` |
| Memory | request `256Mi` / limit `512Mi` |
| replicas | **2** |

**② Bastion에서 실행**

```bash
kubectl create namespace wsc-scaling

cat <<'EOF' > deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wsc-scaling-deploy
  namespace: wsc-scaling
  labels:
    dedicated: scaling
spec:
  replicas: 2
  selector:
    matchLabels:
      app: wsc-scaling-deploy
  template:
    metadata:
      labels:
        app: wsc-scaling-deploy
        dedicated: scaling
    spec:
      containers:
      - name: wsc-scaling-cnt
        image: busybox:latest
        command: ["sleep"]
        args: ["infinity"]
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF

kubectl apply -f deploy.yaml
kubectl get deploy -n wsc-scaling
```

**③ 채점 포인트** — 1-4-A
```
wsc-scaling        Active
wsc-scaling-deploy  2/2   2   2
busybox:latest
```

> ⚠️ 이미지는 반드시 `busybox:latest` (태그 생략 금지 — jsonpath가 문자열 그대로 비교한다).
> ⚠️ 1-6-A 에서 **Pod가 정확히 2개**여야 한다. replicas 2 고정.

---

## 1.7 KEDA + ScaledObject

**① 입력값**

| 항목 | 값 |
|---|---|
| ScaledObject | `wsc-scaling-scaledobject` |
| pollingInterval | **30** (초) |
| queueLength | **5** (메시지 5개당 Pod 1개) |
| minReplicaCount | **2** |
| maxReplicaCount | 20 이상 (100/5 = 20) |

**② KEDA 설치 (Bastion)**

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
kubectl create namespace keda
helm install keda kedacore/keda --namespace keda
kubectl get pods -n keda        # 3개 Running 확인
```

**③ KEDA에 SQS 읽기 권한 부여 (IRSA)**

```bash
CLUSTER=wsc-scaling-cluster
REGION=ap-northeast-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 1) OIDC provider 연결 (콘솔: EKS → 클러스터 → Overview → OpenID Connect provider URL)
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve

# 2) keda-operator SA에 SQS 권한 부여
eksctl create iamserviceaccount \
  --name keda-operator --namespace keda --cluster $CLUSTER --region $REGION \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSFullPolicy \
  --override-existing-serviceaccounts --approve 2>/dev/null \
|| eksctl create iamserviceaccount \
  --name keda-operator --namespace keda --cluster $CLUSTER --region $REGION \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSReadOnlyAccess \
  --override-existing-serviceaccounts --approve

kubectl rollout restart deploy/keda-operator -n keda
```
> 💡 `AmazonSQSFullAccess` 가 정확한 이름이다. 위 명령이 실패하면
> `--attach-policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess` 로 다시 실행.

**④ ScaledObject 생성**

```bash
SQS_URL=$(aws sqs get-queue-url --queue-name wsc-scaling-sqs \
  --region ap-northeast-2 --query QueueUrl --output text)
echo $SQS_URL

cat <<EOF > scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: wsc-scaling-scaledobject
  namespace: wsc-scaling
spec:
  scaleTargetRef:
    name: wsc-scaling-deploy
  pollingInterval: 30
  cooldownPeriod: 60
  minReplicaCount: 2
  maxReplicaCount: 30
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: ${SQS_URL}
      queueLength: "5"
      awsRegion: ap-northeast-2
      identityOwner: operator
EOF

kubectl apply -f scaledobject.yaml
kubectl get scaledobject -n wsc-scaling
kubectl get hpa -n wsc-scaling      # keda-hpa-... 생성 확인
```

**⑤ 채점 포인트** — 1-5-A
```
30      ← .spec.pollingInterval
5       ← .spec.triggers[0].metadata.queueLength
```

> ⚠️ `queueLength` 는 **문자열 `"5"`** 로 넣어야 jsonpath 출력이 `5` 가 된다.
> ⚠️ `identityOwner: operator` 를 빼면 KEDA가 Pod의 SA 권한으로 SQS를 못 읽어 스케일이 안 된다.
> 확인: `kubectl describe scaledobject wsc-scaling-scaledobject -n wsc-scaling` → `Ready True`

---

## 1.8 Karpenter + NodePool

**① 입력값**

| 항목 | 값 |
|---|---|
| NodePool limits | `cpu: 100` / `memory: 200Gi` |
| Consolidation | `WhenEmptyOrUnderutilized` (유휴 노드 자동 제거) |

**② 서브넷/SG에 Karpenter 디스커버리 태그 달기 (콘솔)**

Karpenter는 **태그로** 어디에 노드를 만들지 찾는다. 이걸 빠뜨리면 노드가 안 뜬다.

| 대상 | 태그 Key | 태그 Value |
|---|---|---|
| `wsc-scaling-sn-priv-a`, `wsc-scaling-sn-priv-c` | `karpenter.sh/discovery` | `wsc-scaling-cluster` |
| 노드그룹의 **Cluster security group** | `karpenter.sh/discovery` | `wsc-scaling-cluster` |

> Cluster SG 확인: **EKS → 클러스터 → Networking → Cluster security group**

**③ Karpenter 설치 (Bastion)**

```bash
CLUSTER=wsc-scaling-cluster
REGION=ap-northeast-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
KV=1.8.1     # Karpenter 버전

# Karpenter 컨트롤러용 IRSA (Admin으로 간단히)
eksctl create iamserviceaccount \
  --name karpenter --namespace kube-system --cluster $CLUSTER --region $REGION \
  --attach-policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
  --role-name KarpenterControllerRole-$CLUSTER \
  --override-existing-serviceaccounts --approve

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter --version $KV \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set controller.resources.requests.cpu=200m \
  --set controller.resources.requests.memory=512Mi \
  --wait

kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
```

**④ Karpenter가 만든 노드가 클러스터에 붙도록 Access Entry 추가**

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws eks create-access-entry --cluster-name wsc-scaling-cluster --region ap-northeast-2 \
  --principal-arn arn:aws:iam::${ACCOUNT}:role/wsc-scaling-node-role \
  --type EC2_LINUX 2>/dev/null || echo "이미 존재"
```

**⑤ EC2NodeClass + NodePool**

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

cat <<EOF > karpenter.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: wsc-scaling-node-role
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: wsc-scaling-cluster
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: wsc-scaling-cluster
  tags:
    Name: wsc-scaling-node
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        dedicated: scaling
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large"]
  limits:
    cpu: 100
    memory: 200Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
EOF

kubectl apply -f karpenter.yaml
kubectl get nodepool,ec2nodeclass
```

> ⚠️ `limits.cpu: 100` / `limits.memory: 200Gi` — 과제지 지정값. **따옴표 없이 그대로.**
> ⚠️ `consolidationPolicy: WhenEmptyOrUnderutilized` 가 "유휴 상태의 Node는 자동 제거" 요구사항이다.
> ⚠️ `EC2NodeClass.spec.tags.Name = wsc-scaling-node` → 새 노드에도 Name 태그가 붙는다.

---

## 1.9 스케일링 테스트 (1-6 채점 재현)

```bash
# ── 사전 상태 (Pod 2개 / Node 2개)
kubectl get po -n wsc-scaling
kubectl get nodes

# ── SQS에 메시지 100건 투입
SQS_URL=$(aws sqs get-queue-url --queue-name wsc-scaling-sqs --query 'QueueUrl' --output text)
for n in {1..100}; do
  aws sqs send-message --queue-url "$SQS_URL" --message-body "EKS Scaling Test $n" > /dev/null
  echo "EKS Scaling Test: $n"
done
sleep 60

# ── 결과 (최대 3분 대기)
kubectl get po -n wsc-scaling    # Pod 19~20개
kubectl get nodes                # 기존 2 + Karpenter 2 = 총 4개
```

**③ 채점 포인트** — 1-6-C
- Pod **19~20개** Running (100 ÷ queueLength 5 = 20)
- Node **4개** Ready (`ip-10-11-*.ap-northeast-2.compute.internal`)

> ⚠️ 노드가 안 늘면: `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50`
> 대개 **서브넷/SG 태그 누락** 또는 **NodePool limits 초과**다.
> ⚠️ Pod가 안 늘면: `kubectl describe scaledobject -n wsc-scaling` → SQS 권한(IRSA) 확인.

---
---

# 2️⃣ VPC Lattice — `ap-southeast-1`

> **목표**: Hub VPC의 Bastion → **VPC Lattice** → Spoke VPC의 앱(v1/v2)
> 헤더 `version: v1` → v1으로, 없으면 **90:10 가중치 분산**.

## 2.0 이 모듈의 구조 (먼저 이해하고 시작)

```
[Hub VPC 10.0.0.0/16]                    [Spoke VPC 192.168.0.0/16]
  wsc-hub-bastion ──┐                      wsc-spoke-app-v1 :8080 ─┐
   (pub-a, EIP)     │                      wsc-spoke-app-v2 :8080 ─┤
                    │                          (priv-a)            │
                    ▼                                              │
        ┌───────────────────────────────┐                          │
        │  VPC Lattice Service Network  │                          │
        │   wsc-app-service-network     │◀── VPC 연결(Hub+Spoke)    │
        │                               │                          │
        │  Service: wsc-app-service     │                          │
        │   Listener HTTP 80            │                          │
        │   ├ Rule 10  header v1 → v1-tg│──────────────────────────┘
        │   ├ Rule 20  header v2 → v2-tg│
        │   └ Default  v1:90 / v2:10    │
        └───────────────────────────────┘

  별도로: Internal ALB (wsc-spoke-app-alb) + ELB TG 2개
          → /healthcheck 403, 그 외 404 규칙 담당
```

> ### ⚠️ 중요한 해석 포인트 (읽고 넘어갈 것)
> 채점표를 보면 **같은 이름의 Target Group이 두 벌** 필요하다.
> - `aws elbv2 describe-target-groups --names wsc-spoke-v1-tg wsc-spoke-v2-tg` → **ELB TG** (2-2-A)
> - `aws vpc-lattice get-target-group --target-group-identifier ...` → **Lattice TG** (2-4/2-5-A)
>
> Lattice TG를 `ALB` 타입으로 만들면 **ALB가 하나뿐이라 v1/v2를 나눌 수 없다**
> (2-6-A의 `curl -H "version: v1"` 이 항상 같은 결과를 준다).
> 따라서 **Lattice TG는 `INSTANCE` 타입**으로 각 EC2를 직접 가리키게 만든다.
> ELB TG 2개는 2-2-A 채점과 헬스체크(2-6-A 앞부분)를 위해 **그대로 유지**한다.

## 2.1 VPC 2개

**① 입력값**

| VPC | 이름 | CIDR | 서브넷 |
|---|---|---|---|
| Hub | `wsc-hub-vpc` | `10.0.0.0/16` | `wsc-hub-sn-pub-a` 10.0.0.0/24 (2a)<br>`wsc-hub-sn-pub-c` 10.0.1.0/24 (2c) |
| Spoke | `wsc-spoke-vpc` | `192.168.0.0/16` | `wsc-spoke-sn-pub-a` 192.168.0.0/24<br>`wsc-spoke-sn-pub-c` 192.168.1.0/24<br>`wsc-spoke-sn-priv-a` 192.168.2.0/24<br>`wsc-spoke-sn-priv-c` 192.168.3.0/24 |

> AZ는 `ap-southeast-1a` / `ap-southeast-1c` (이름 뒤 알파벳 = 가용영역)

**② 클릭 순서**

1. 리전을 **ap-southeast-1 (Singapore)** 로 변경 ⚠️
2. **VPC → Create VPC → VPC and more**
   - Name `wsc-hub`, CIDR `10.0.0.0/16`, AZ 2, Public 2, **Private 0**, NAT **None**
   - 생성 후 서브넷 이름을 `wsc-hub-sn-pub-a`, `wsc-hub-sn-pub-c` 로 수정
3. 다시 **Create VPC → VPC and more**
   - Name `wsc-spoke`, CIDR `192.168.0.0/16`, AZ 2, Public 2, Private 2, **NAT: In 1 AZ**
   - 서브넷 이름 4개 수정
4. 두 VPC 모두 **Enable DNS hostnames / DNS resolution** ✅
5. Public 서브넷 전부 **auto-assign public IPv4** ✅

**③ 채점 포인트** — 2-1-A (VPC 2개 + 서브넷 6개 CIDR 정확히 일치)

---

## 2.2 Bastion (`wsc-hub-bastion`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Name | `wsc-hub-bastion` |
| Type | **t3.small** |
| Subnet | `wsc-hub-sn-pub-a` |
| Public IP | **Elastic IP** (재시작해도 불변) |
| SSH | **패스워드 방식**, `ec2-user` / `Skill53##` |
| IAM Role | Admin (`wsc-bastion-role`) |

**② User Data** (인스턴스 생성 시 Advanced details → User data)

```bash
#!/bin/bash
dnf install -y jq
echo 'ec2-user:Skill53##' | chpasswd
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf
systemctl restart sshd
```

**③ EIP 연결** — *EC2 → Elastic IPs → Allocate → Associate*

> ⚠️ **접속 불가 = 이 모듈 0점.** 만든 직후 `ssh ec2-user@<EIP>` 로 패스워드 로그인이 되는지 **꼭 확인**.
> ⚠️ 채점자는 여기서 `mark2.sh` 를 돌린다. `jq` 와 `aws` CLI가 있어야 한다.

---

## 2.3 App 서버 (`wsc-spoke-app-v1` / `wsc-spoke-app-v2`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Name | `wsc-spoke-app-v1`, `wsc-spoke-app-v2` |
| Type | **t3.medium** |
| Subnet | `wsc-spoke-sn-priv-a` (둘 다 AZ A) |
| Port | **TCP 8080** (Flask) |

**② User Data — v1** (v2는 `version1.py`→`version2.py`, `'v1'`→`'v2'` 만 바꾼다)

```bash
#!/bin/bash
dnf install -y python3-pip
pip3 install flask
mkdir -p /opt/app
cat <<'PYEOF' > /opt/app/version1.py
from flask import Flask, jsonify, request

app = Flask(__name__)

@app.route('/version', methods=['GET'])
def get_version():
    return jsonify({'version': 'v1'}), 200

@app.route('/healthcheck', methods=['GET'])
def get_healthcheck():
    return jsonify({'status': 'ok'}), 200

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=8080)
PYEOF

cat <<'SVCEOF' > /etc/systemd/system/app.service
[Unit]
Description=WSC App
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/app/version1.py
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now app
```

> ⚠️ 배포파일 `version1.py` / `version2.py` **원본을 그대로** 쓴다 (과제지: 임의 수정 금지).
> 위 User Data는 원본과 동일한 응답을 낸다. 실제 배포파일을 S3/scp로 올려 쓰는 편이 안전하다.

**③ 보안그룹** — `wsc-spoke-app-sg`

| 방향 | 포트 | 소스 | 이유 |
|---|---|---|---|
| Inbound | TCP 8080 | `wsc-spoke-alb-sg` | ALB → 앱 |
| Inbound | TCP 8080 | **`com.amazonaws.ap-southeast-1.vpc-lattice` (Managed prefix list)** | **Lattice → 앱** |
| Inbound | TCP 8080 | `192.168.0.0/16` | (대체) |
| Outbound | All | 0.0.0.0/0 | |

> ⚠️ **Lattice 관리형 접두사 목록(prefix list)을 인바운드에 허용하지 않으면 Lattice TG가 절대 healthy가 되지 않는다.**
> *EC2 → Security Groups → Edit inbound rules → Source: Custom → `pl-` 검색 → `com.amazonaws.ap-southeast-1.vpc-lattice`*

---

## 2.4 Internal ALB + ELB Target Group

**① 입력값**

| 항목 | 값 |
|---|---|
| ALB Name | `wsc-spoke-app-alb` |
| Scheme | **internal** |
| Listener | **HTTP 80** |
| Subnets | `wsc-spoke-sn-priv-a`, `wsc-spoke-sn-priv-c` |
| TG | `wsc-spoke-v1-tg` (HTTP **8080** → app-v1)<br>`wsc-spoke-v2-tg` (HTTP **8080** → app-v2) |
| Health check | `/healthcheck` |

**② 클릭 순서**

1. **EC2 → Target Groups → Create target group**
   - Type **Instances** / Name `wsc-spoke-v1-tg` / Protocol **HTTP** / Port **8080**
   - VPC `wsc-spoke-vpc` / Health check path `/healthcheck`
   - Register targets → `wsc-spoke-app-v1` (port 8080) → Create
2. 동일하게 `wsc-spoke-v2-tg` (→ `wsc-spoke-app-v2`)
3. **EC2 → Load Balancers → Create → Application Load Balancer**
   - Name `wsc-spoke-app-alb` / Scheme **Internal** / IPv4
   - VPC `wsc-spoke-vpc` / Subnets **priv-a, priv-c**
   - SG `wsc-spoke-alb-sg` (inbound 80 from 192.168.0.0/16 + 10.0.0.0/16)
   - Listener **HTTP 80** → Default action: **Return fixed response**
     - Status **404** / Content type `text/plain` / Body `Not Found`
   - Create

4. **Listener rules 추가** (Listener HTTP:80 → *Manage rules*)

| 우선순위 | 조건 | 동작 |
|---|---|---|
| **1** | Path = `/healthcheck` | **Fixed response 403** / body `Restrict access to api` |
| **2** | Path = `/version` | **Forward** → `wsc-spoke-v1-tg` **90%**, `wsc-spoke-v2-tg` **10%** |
| default | — | **Fixed response 404** / body `Not Found` |

**③ 채점 포인트** — 2-2-A
```
wsc-spoke-app-alb   internal   application   active
wsc-spoke-v1-tg HTTP  8080
wsc-spoke-v2-tg HTTP  8080
```
2-6-A 앞부분 → 두 TG 모두 `healthy`

> ⚠️ TG 포트는 **8080** (앱 포트). ALB 리스너 포트는 **80**. 헷갈리지 말 것.
> ⚠️ ALB 헬스체크는 TG로 **직접** 가므로 `/healthcheck` 가 200을 반환한다.
> 리스너 규칙의 403은 **ALB를 거쳐 들어온 요청**에만 적용된다.

---

## 2.5 VPC Lattice 구성

**① 입력값**

| 항목 | 값 |
|---|---|
| Service Network | `wsc-app-service-network` |
| Service | `wsc-app-service` |
| Listener | HTTP **80** |
| VPC associations | **`wsc-hub-vpc` + `wsc-spoke-vpc`** (2개 모두) |
| Lattice TG | `wsc-spoke-v1-tg` (INSTANCE, HTTP 8080 → app-v1)<br>`wsc-spoke-v2-tg` (INSTANCE, HTTP 8080 → app-v2) |

**② Lattice Target Group 2개 생성**

1. **VPC → VPC Lattice → Target groups → Create target group**
2. Target type **Instances** / Name `wsc-spoke-v1-tg`
3. VPC `wsc-spoke-vpc` / Protocol **HTTP** / Port **8080** / Version HTTP1
4. Health check: **Enable**, path `/healthcheck`
5. Next → Targets에서 `wsc-spoke-app-v1` 선택 → port **8080** → **Create**
6. 동일하게 `wsc-spoke-v2-tg` (→ `wsc-spoke-app-v2`)

> 💡 ELB TG와 이름이 같아도 **서비스가 달라 충돌하지 않는다.** 채점표가 요구하는 대로다.

**③ Service Network 생성**

1. **VPC Lattice → Service networks → Create service network**
2. Name `wsc-app-service-network`
3. **VPC associations** → `wsc-hub-vpc` **와** `wsc-spoke-vpc` 둘 다 추가
   - Security groups: 80/8080 허용 SG 선택 (없으면 새로 만들어 `0.0.0.0/0:80` inbound)
4. Auth type: **None** (또는 IAM, 요구 없음 → None이 안전)
5. **Create**

**④ Service 생성**

1. **VPC Lattice → Services → Create service**
2. Name `wsc-app-service` / Auth **None**
3. **Create** → 생성 후 *Service network associations* 에 `wsc-app-service-network` 연결

**⑤ Listener + Rule**

1. Service → *Routing* 탭 → **Add listener**
   - Name `http-80` / Protocol **HTTP** / Port **80**
   - **Default action** → *Forward to multiple target groups*
     - `wsc-spoke-v1-tg` weight **90**
     - `wsc-spoke-v2-tg` weight **10**
   - **Add listener**
2. Listener → **Rules** 탭 → **Add rule**

| 이름 | Priority | 조건 | 동작 |
|---|---|---|---|
| `v1-rule` | **10** | HTTP header `version` **Exact** = `v1` | Forward → `wsc-spoke-v1-tg` **100** |
| `v2-rule` | **20** | HTTP header `version` **Exact** = `v2` | Forward → `wsc-spoke-v2-tg` **100** |

> ⚠️ Priority 숫자가 **작을수록 먼저** 평가된다 → 헤더 규칙(10/20)이 Default(99999)보다 우선.
> ⚠️ 헤더 매칭은 **Exact**(정확히 일치). Prefix/Contains 로 하면 채점 스크립트의
> `.match.httpMatch.headerMatches[0].match.exact` 가 `null` 이 되어 0점.

**⑥ 채점 포인트**

2-3-A
```
wsc-app-service-network
wsc-app-service
wsc-spoke-vpc
wsc-hub-vpc
```
2-4-A (Default rule)
```
Priority=99999 | Header=default | Targets=wsc-spoke-v1-tg:90 wsc-spoke-v2-tg:10
```
2-5-A (Header rule)
```
Priority=20 | Header=v2 | Targets=wsc-spoke-v2-tg:100
Priority=10 | Header=v1 | Targets=wsc-spoke-v1-tg:100
```

---

## 2.6 Hub Bastion에서 최종 확인 (2-6 재현)

```bash
# ELB TG 헬스
for TG_NAME in wsc-spoke-v1-tg wsc-spoke-v2-tg; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  STATUS=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "TargetHealthDescriptions[0].TargetHealth.State" --output text)
  echo "$TG_NAME  $STATUS"
done

# Lattice DNS로 호출
SVC_ID=$(aws vpc-lattice list-services \
  --query "items[?name=='wsc-app-service'].id" --output text)
LATTICE_DNS=$(aws vpc-lattice get-service --service-identifier "$SVC_ID" \
  --query "dnsEntry.domainName" --output text)

curl -s -H "version: v1" http://$LATTICE_DNS/version    # {"version":"v1"}
curl -s -H "version: v2" http://$LATTICE_DNS/version    # {"version":"v2"}
curl -s http://$LATTICE_DNS/version                     # 90:10 분산
```

**기대 출력**
```
wsc-spoke-v1-tg  healthy
wsc-spoke-v2-tg  healthy
{"version":"v1"}
{"version":"v2"}
```

> ⚠️ Lattice DNS가 **Hub Bastion에서 안 풀리면** Service Network에 `wsc-hub-vpc` 연결이 빠진 것이다.
> ⚠️ `curl` 이 타임아웃 → App EC2의 SG에 **vpc-lattice prefix list** 인바운드 8080이 없다.

---
---

# 3️⃣ Container Logging — `ap-northeast-1`

> **목표**: EC2의 Docker 컨테이너 로그 → **Fluent Bit(호스트, systemd)** → **Loki(EKS, NLB)** → **Grafana 대시보드**
> 로그 발생 ~ 대시보드 도달까지 **10초 이내**.

## 3.1 VPC 구성

| 리소스 | 이름 | CIDR |
|---|---|---|
| VPC | `wsc-logging-vpc` | `10.3.0.0/16` |
| Public a | `wsc-logging-sn-pub-a` | 10.3.0.0/24 |
| Public c | `wsc-logging-sn-pub-c` | 10.3.1.0/24 |
| Private a | `wsc-logging-sn-priv-a` | 10.3.2.0/24 |
| Private c | `wsc-logging-sn-priv-c` | 10.3.3.0/24 |

**② 클릭 순서** — 리전 **ap-northeast-1 (Tokyo)** 확인 후 모듈1과 동일하게 *VPC and more* 로 생성.
NAT Gateway는 **필수** (private 노드가 이미지/헬름을 받아야 함).

> 🚨 **채점 스크립트 오타 주의**
> 3-1-A 스크립트는 VPC를 `Name=wsc-log-vpc` 로, 3-6-C는 EC2를 `wsc-log-app-bastion` 으로 찾는다.
> **과제지에는 `wsc-logging-vpc` / `wsc-logging-app-bastion`** 이다.
> → **과제지 이름을 정본으로 쓰되**, 안전하게 **두 이름의 태그를 모두 달아두는 것을 권장**한다.
> (Name 태그는 하나뿐이므로, VPC에 `Name=wsc-logging-vpc` + 추가 태그 `wsc-log-vpc`는 불가.
>  → 채점 시 스크립트가 빈 값을 뱉으면 **즉시 이의제기**하고 수동 채점을 요청할 것.)

---

## 3.2 EKS 클러스터 + NodeGroup

| 항목 | 값 |
|---|---|
| Cluster | `wsc-logging-cluster` / **1.35** |
| NodeGroup | `wsc-logging-ng` |
| Min / Desired / Max | **2 / 2 / 4** |
| Type / AMI | **t3.medium** / Amazon Linux 2023 |
| Node Name 태그 | `wsc-logging-node` |
| Subnets | private 2개 |

**② 클릭 순서** — 모듈 1.4 / 1.5 와 동일. 단 스케일링만 **2/2/4**.

**③ 채점 포인트** — 3-1-A
```
10.3.0.0/16
wsc-logging-sn-pub-a   10.3.0.0/24
wsc-logging-sn-priv-a  10.3.2.0/24
wsc-logging-sn-pub-c   10.3.1.0/24
wsc-logging-sn-priv-c  10.3.3.0/24
wsc-logging-cluster    1.35
[ "wsc-logging-ng", { "minSize": 2, "maxSize": 4, "desiredSize": 2 } ]
```

> ⚠️ 이 모듈은 **Bastion이 곧 앱 서버**(`wsc-logging-app-bastion`)다.
> `mark3.sh` 를 여기서 돌리므로 kubectl / helm / awscli / jq 전부 여기에 설치한다.

---

## 3.3 EBS CSI Driver (Loki PVC 10Gi용)

Loki가 `filesystem` 스토리지 + PVC 10Gi 를 쓰므로 **StorageClass가 필요**하다.
EKS 1.30+ 는 EBS CSI 드라이버가 기본 설치되지 않는다.

1. **IAM → Create role → Web identity** (또는 eksctl)
```bash
CLUSTER=wsc-logging-cluster
REGION=ap-northeast-1
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve

eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa --namespace kube-system \
  --cluster $CLUSTER --region $REGION \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --role-name AmazonEKS_EBS_CSI_DriverRole_$CLUSTER \
  --role-only --approve

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws eks create-addon --cluster-name $CLUSTER --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::${ACCOUNT}:role/AmazonEKS_EBS_CSI_DriverRole_${CLUSTER}
```
> 콘솔로 하려면: **EKS → 클러스터 → Add-ons → Get more add-ons → Amazon EBS CSI Driver**

2. 기본 StorageClass 지정
```bash
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## 3.4 Loki 설치 (Helm)

| 항목 | 값 |
|---|---|
| namespace | `wsc-logging` |
| Deploy Mode | **SingleBinary** |
| Storage | filesystem, PVC **10Gi** |
| Port | **3100** |
| Service | **LoadBalancer (NLB, internet-facing)** |
| Helm release | `loki` |

```bash
aws eks update-kubeconfig --region ap-northeast-1 --name wsc-logging-cluster
kubectl create namespace wsc-logging

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

cat <<'EOF' > loki-values.yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    reject_old_samples: false
    allow_structured_metadata: false

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi

# SingleBinary 이외 컴포넌트 전부 끄기
read:      { replicas: 0 }
write:     { replicas: 0 }
backend:   { replicas: 0 }
chunksCache:   { enabled: false }
resultsCache:  { enabled: false }
lokiCanary:    { enabled: false }
test:          { enabled: false }
gateway:       { enabled: false }
monitoring:
  selfMonitoring: { enabled: false, grafanaAgent: { installOperator: false } }

# NLB 로 노출
service:
  type: LoadBalancer
  port: 3100
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
EOF

helm install loki grafana/loki -n wsc-logging -f loki-values.yaml

kubectl get pods -n wsc-logging
kubectl get svc  -n wsc-logging
```

**③ 채점 포인트** — 3-2-A
```
STATUS
Running
a11c8436....elb.ap-northeast-1.amazonaws.com     ← loki svc EXTERNAL-IP
```

> ⚠️ Service 이름이 `loki` 인 것 중 **LoadBalancer 타입**이 있어야 한다.
> 채점 스크립트: `kubectl get svc -n wsc-logging -l app.kubernetes.io/name=loki | grep LoadBalancer`
> ⚠️ `loki-gateway` 만 LB로 뜨면 안 된다. 위 values는 gateway를 끄고 `loki` svc를 LB로 만든다.
> ⚠️ Pod 라벨 `app.kubernetes.io/component=single-binary` 가 있어야 3-2-A 첫 줄이 나온다 → SingleBinary 모드 필수.
> ⚠️ **NLB가 internet-facing 이려면 public 서브넷에 `kubernetes.io/role/elb=1` 태그**가 필요하다.
> *VPC → Subnets → public 2개 → Tags → Add: `kubernetes.io/role/elb` = `1`*

---

## 3.5 Grafana 설치 (Helm)

| 항목 | 값 |
|---|---|
| namespace | `wsc-logging` |
| Helm release | `grafana` |
| Admin | ID `wsc2026-admin-{비번호}` / PW `admin{비번호}!` |
| Dashboard | **WSC2026 Container Logs** |
| Refresh | **5s**, 시간 범위 **1h** |
| Service | LoadBalancer (NLB) |

```bash
NM=<본인 비번호>       # 예: 07

cat <<EOF > grafana-values.yaml
adminUser: wsc2026-admin-${NM}
adminPassword: "admin${NM}!"

service:
  type: LoadBalancer
  port: 80
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.wsc-logging.svc.cluster.local:3100
        isDefault: true

dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

dashboardsConfigMaps:
  default: grafana-wsc-dashboard
EOF
```

**대시보드 ConfigMap** (패널 4종 · refresh 5s · 1시간 범위)

```bash
cat <<'EOF' > dashboard.json
{
  "title": "WSC2026 Container Logs",
  "uid": "wsc2026-container-logs",
  "timezone": "Asia/Seoul",
  "refresh": "5s",
  "time": { "from": "now-1h", "to": "now" },
  "schemaVersion": 39,
  "panels": [
    {
      "type": "logs", "title": "Any Log", "id": 1,
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "{namespace=\"wsc-app-log\"}", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "INFO Log Count", "id": 2,
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 10 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"INFO\" [1m])", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "ERROR Log Count", "id": 3,
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 10 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"ERROR\" [1m])", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "WARNING Log Count", "id": 4,
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 10 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"WARNING\" [1m])", "refId": "A" } ]
    }
  ]
}
EOF

kubectl create configmap grafana-wsc-dashboard \
  -n wsc-logging --from-file=dashboard.json

helm install grafana grafana/grafana -n wsc-logging -f grafana-values.yaml

kubectl get svc -n wsc-logging -l app.kubernetes.io/name=grafana
```

**③ 채점 포인트**
- 3-2-A 뒷부분 → grafana Pod `Running` + svc `LoadBalancer` EXTERNAL-IP
- 3-6-A → `curl -u wsc2026-admin-$NM:admin$NM! http://$GRAFANA_LB/api/search?type=dash-db` → **1 dashboards**
- 3-6-B (수동) → 브라우저 접속 → Dashboards → **WSC2026 Container Logs** → 4패널 + Inspect > Query 로 LogQL 확인

> ⚠️ 대시보드 4개 패널의 **제목·LogQL·시각화 타입**이 채점표와 정확히 같아야 한다 (수동채점 1.5점).
> ⚠️ Grafana 로그인 비번의 `!` 때문에 bash에서 `curl -u ...admin07!` 이 히스토리 확장될 수 있다 → **작은따옴표**로 감싸라.

---

## 3.6 EC2 앱 서버 (`wsc-logging-app-bastion`)

| 항목 | 값 |
|---|---|
| Name | `wsc-logging-app-bastion` |
| Type / AMI | **t3.small** / Amazon Linux 2023 |
| Subnet | `wsc-logging-sn-pub-a` (Public, EIP 권장) |
| Container | `wsc-log-app` |
| Port | **TCP 5000** |
| IAM Role | Admin + **`AmazonSSMManagedInstanceCore`** |

**② SG** — inbound 22 (SSH), **5000** (0.0.0.0/0), outbound All

**③ 배포파일 업로드** — 로컬에서
```bash
scp -i wsc-key.pem -r app/ ec2-user@<EIP>:~/app/
# app/app.py, app/requirements.txt, app/Dockerfile  (배포파일 원본, 수정 금지)
```

**④ Docker 실행**
```bash
sudo dnf install -y docker jq
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user && newgrp docker

cd ~/app
docker build -t wsc-log-app:latest .
docker run -d --name wsc-log-app \
  --restart always \
  --log-driver json-file \
  -p 5000:5000 \
  wsc-log-app:latest

curl -s localhost:5000/health     # {"status":"ok"}
```

> ⚠️ `--restart always` (항상 재시작) · `--log-driver json-file` (Docker 기본 드라이버) — 과제지 명시.
> ⚠️ 컨테이너 이름은 정확히 `wsc-log-app`.

**⑤ 채점 포인트**
- 3-3-A → `curl http://<PublicIP>:5000/health` → `{"status":"ok"}`
- 3-6-C → `/` `{"service": "m3-log-generator", "status": "healthy"}` , `/generate?count=30` → `"generated": 30,`

---

## 3.7 Fluent Bit (호스트 설치 + systemd)

```bash
# 설치 (AL2023)
curl -fsSL https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sudo sh
# → /opt/fluent-bit/ 에 설치, systemd unit 이름은 fluent-bit

# Loki NLB 주소 확보 (Bastion에 kubectl 세팅 후)
LOKI_LB=$(kubectl get svc -n wsc-logging -l app.kubernetes.io/name=loki \
  | grep LoadBalancer | awk '{ print $4 }')
echo $LOKI_LB
```

**설정 파일** `/etc/fluent-bit/fluent-bit.conf`

```bash
sudo tee /etc/fluent-bit/fluent-bit.conf > /dev/null <<EOF
[SERVICE]
    Flush         1
    Daemon        Off
    Log_Level     info
    Parsers_File  /etc/fluent-bit/parsers.conf

[INPUT]
    Name              tail
    Tag               docker.*
    Path              /var/lib/docker/containers/*/*.log
    Parser            docker
    DB                /var/log/flb_docker.db
    Mem_Buf_Limit     5MB
    Skip_Long_Lines   On
    Refresh_Interval  1

[FILTER]
    Name          record_modifier
    Match         docker.*
    Record        namespace wsc-app-log

[OUTPUT]
    Name          loki
    Match         docker.*
    Host          ${LOKI_LB}
    Port          3100
    Labels        namespace=\$namespace
    Line_Format   json
    Auto_Kubernetes_Labels off
EOF
```

**Docker 로그 파서** `/etc/fluent-bit/parsers.conf` 에 추가 (없으면)

```bash
sudo tee -a /etc/fluent-bit/parsers.conf > /dev/null <<'EOF'

[PARSER]
    Name         docker
    Format       json
    Time_Key     time
    Time_Format  %Y-%m-%dT%H:%M:%S.%L
    Time_Keep    On
EOF
```

**타임존 + 서비스 기동**

```bash
sudo timedatectl set-timezone Asia/Seoul

sudo mkdir -p /etc/systemd/system/fluent-bit.service.d
sudo tee /etc/systemd/system/fluent-bit.service.d/tz.conf > /dev/null <<'EOF'
[Service]
Environment=TZ=Asia/Seoul
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now fluent-bit
systemctl is-active fluent-bit          # → active
sudo journalctl -u fluent-bit -n 30 --no-pager
```

**③ 채점 포인트**
- 3-4-A → SSM Send-Command 로 `systemctl is-active fluent-bit` → **`active`**
- 3-5-B → Loki 쿼리 `{namespace="wsc-app-log"}` → **1 streams 이상**

> ⚠️ `Time_Format %Y-%m-%dT%H:%M:%S.%L` + `TZ=Asia/Seoul` — 과제지 명시.
> ⚠️ **SSM 이 안 붙으면 3-4는 0점.** Public 서브넷 + Admin/SSM Role + 아웃바운드 443 → `aws ssm describe-instance-information` 으로 확인.
> ⚠️ `Labels namespace=$namespace` 의 `$` 는 heredoc에서 `\$` 로 이스케이프해야 그대로 들어간다.

---

## 3.8 E2E 테스트 (3-5 재현)

```bash
EC2_IP=$(aws ec2 describe-instances --region ap-northeast-1 \
  --filters "Name=tag:Name,Values=wsc-logging-app-bastion" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

curl -s "http://$EC2_IP:5000/generate?count=30" > /dev/null 2>&1
sleep 10

LOKI_LB=$(kubectl get svc -n wsc-logging -l app.kubernetes.io/name=loki \
  | grep LoadBalancer | awk '{ print $4 }')
curl -sG "http://$LOKI_LB:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="wsc-app-log"}' \
  --data-urlencode 'limit=10' \
| python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])), 'streams found')"
```
기대: `3 streams found` (1개 이상이면 통과)

---
---

# 4️⃣ REST API Implement — `us-east-1`

> **목표**: API Gateway(REST) + Lambda(python3.14) + DynamoDB 로 **멱등한** 사용자 API.
> API Key 없으면 403, 잘못된 요청은 **Lambda까지 가지 않아야** 한다.

## 4.1 DynamoDB (`wsc-rest-table`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Table name | `wsc-rest-table` |
| Partition key | `name` (**String**) |
| Sort key | 없음 |
| Capacity | **On-demand** |

**② 클릭 순서**
1. 리전 **us-east-1** 확인 ⚠️
2. **DynamoDB → Tables → Create table**
3. Table name `wsc-rest-table` / Partition key `name` **String**
4. Table settings → **Customize settings** → Capacity mode **On-demand**
5. **Create table**

**③ 채점 포인트** — 4-1-A `wsc-rest-table`

> ⚠️ **On-demand 필수**. 과제지 "3000 RPS 이상 Burst Traffic 환경에서도 안정적으로 동작" 요구.
> Provisioned로 만들면 서술형 요구를 못 채운다.
> ⚠️ `age`, `country` 는 **키가 아니므로 테이블 정의에 넣지 않는다** (NoSQL 스키마리스).
> `age` 는 저장할 때 **Number 타입**으로 넣는다 (Lambda 코드에서 `int`).

---

## 4.2 Lambda (`wsc-rest-function`)

**① 입력값**

| 항목 | 값 |
|---|---|
| Function name | `wsc-rest-function` |
| Runtime | **Python 3.14** |
| Handler | `lambda_function.lambda_handler` |
| Timeout | 10초 |
| 권한 | DynamoDB `GetItem`, `PutItem` |

**② 클릭 순서**

1. **Lambda → Create function → Author from scratch**
2. Name `wsc-rest-function` / Runtime **Python 3.14** / Arch x86_64
3. Change default execution role → **Create a new role with basic Lambda permissions**
4. **Create function**
5. *Configuration → Permissions* → Role 클릭 → **Add permissions → Attach policies**
   → `AmazonDynamoDBFullAccess` (또는 인라인으로 GetItem/PutItem만)
6. *Configuration → General configuration* → Timeout **10 sec**

**③ 코드** (`lambda_function.py`)

```python
import json
import os
import boto3
from botocore.exceptions import ClientError

# ── boto3 client는 핸들러 밖에서 1회 생성 → Connection Reuse
#    (과제지: "boto3 Client 재사용 및 Connection Reuse를 고려")
TABLE_NAME = os.environ.get("TABLE_NAME", "wsc-rest-table")
_dynamodb = boto3.client("dynamodb")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _create_user(payload):
    name = payload["name"]
    age = int(payload["age"])
    country = payload["country"]

    try:
        # Conditional Write → Retry-safe (중복 저장 방지, 멱등성 보장)
        _dynamodb.put_item(
            TableName=TABLE_NAME,
            Item={
                "name": {"S": name},
                "age": {"N": str(age)},
                "country": {"S": country},
            },
            ConditionExpression="attribute_not_exists(#n)",
            ExpressionAttributeNames={"#n": "name"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _response(409, {"message": "User already exists"})
        raise

    return _response(201, {"message": "User created successfully"})


def _get_user(params):
    name = params["name"]

    item = _dynamodb.get_item(
        TableName=TABLE_NAME,
        Key={"name": {"S": name}},
        ConsistentRead=True,
    ).get("Item")

    if not item:
        return _response(404, {"message": "User not found"})

    return _response(200, {
        "name": item["name"]["S"],
        "country": item["country"]["S"],
        "age": int(item["age"]["N"]),
    })


def lambda_handler(event, context):
    # Exception 발생 시 Stack Trace가 외부에 노출되면 안 된다 → 전부 감싼다
    try:
        method = event.get("httpMethod", "")

        if method == "POST":
            body = json.loads(event.get("body") or "{}")
            return _create_user(body)

        if method == "GET":
            params = event.get("queryStringParameters") or {}
            return _get_user(params)

        return _response(405, {"message": "Method Not Allowed"})

    except (KeyError, ValueError, TypeError):
        return _response(400, {"message": "Invalid request"})
    except Exception:
        # 내부 예외 정보를 절대 반환하지 않는다
        return _response(500, {"message": "Internal Server Error"})
```

7. **Deploy** 클릭

**④ 채점 포인트** — 4-1-A
```
wsc-rest-function
python3.14
```

> ⚠️ 응답 순서 `{"name", "country", "age"}` — 4-3-A 기대출력과 **키 순서까지** 같게 맞춘 것이다.
> ⚠️ `age` 는 **숫자** `19` (문자열 `"19"` 아님).
> ⚠️ 중복 POST → `{"message": "User already exists"}` , 없는 사용자 GET → `{"message": "User not found"}`.
> ⚠️ Stack Trace 노출 금지 → `raise` 를 핸들러 밖으로 던지지 않는다.

---

## 4.3 API Gateway (`wsc-rest-api`)

**① 리소스 트리**

```
/
└── v1
    ├── user           POST  (Lambda proxy, API Key 필수, Body Validator)
    │                  GET   (Lambda proxy, API Key 필수, Query Validator)
    └── healthcheck    GET   (MOCK, API Key 불필요)
```

**② API 생성**

1. **API Gateway → Create API → REST API → Build** (Private/HTTP 아님 ⚠️)
2. API name `wsc-rest-api` / Endpoint type **Regional** → **Create API**

**③ 리소스 만들기**

1. *Resources* → **Create resource** → Resource name `v1` → Create
2. `/v1` 선택 → **Create resource** → `user` → Create
3. `/v1` 선택 → **Create resource** → `healthcheck` → Create

**④ `/v1/user` POST**

1. `/v1/user` → **Create method** → **POST**
2. Integration type **Lambda function** / **Lambda proxy integration ✅ ON**
3. Lambda function `wsc-rest-function` → **Create method**
4. *Method request* → **Edit**
   - **API key required: ✅ True**
   - Request validator: **Validate body**
   - Request body → **Add model**: Content type `application/json`, Model `UserModel`

**모델 만들기** — *Models → Create model*

| 항목 | 값 |
|---|---|
| Name | `UserModel` |
| Content type | `application/json` |

```json
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "title": "UserModel",
  "type": "object",
  "required": ["name", "age", "country"],
  "properties": {
    "name":    { "type": "string", "minLength": 1 },
    "age":     { "type": "integer", "minimum": 0 },
    "country": { "type": "string", "minLength": 1 }
  }
}
```

**⑤ `/v1/user` GET**

1. `/v1/user` → **Create method** → **GET**
2. Lambda proxy integration ✅ / `wsc-rest-function`
3. *Method request* → **Edit**
   - **API key required: ✅ True**
   - Request validator: **Validate query string parameters and headers**
   - **URL query string parameters** →
     - `name` **Required ✅**
     - `age`  **Required ✅**

> ⚠️ 이 설정 덕분에 `?name=nobody` 만 보내면 API GW가 Lambda 호출 없이
> `{"message": "Missing required request parameters: [age]"}` 를 반환한다 (4-6-A).
> **직접 만드는 게 아니라 API Gateway 기본 Gateway Response** 다. 건드리지 말 것.

**⑥ `/v1/healthcheck` GET (MOCK)**

1. `/v1/healthcheck` → **Create method** → **GET**
2. Integration type **Mock** → **API key required: ❌ False** → Create
3. *Integration request* → Mapping templates → `application/json`
   ```json
   {"statusCode": 200}
   ```
4. *Integration response* → 200 → Mapping templates → `application/json`
   ```json
   {"status": "ok"}
   ```
5. *Method response* → 200 이 있는지 확인 (없으면 추가)

**⑦ 채점 포인트** — 4-2-A
```
{"status":"ok"}
```

---

## 4.4 API Key + Usage Plan

1. **API Gateway → API Keys → Create API key**
   - Name `wsc-rest-api-key` / API key **Auto generate** → **Save**
2. **Usage plans → Create usage plan**
   - Name `wsc-rest-plan` / Throttling·Quota는 기본 또는 넉넉히 (예: rate 10000, burst 5000)
3. 생성된 플랜 → *Associated stages* → **Add stage** → API `wsc-rest-api` / Stage `prod`
   (※ 스테이지가 없으면 **4.5 배포를 먼저** 하고 돌아온다)
4. → *Associated API keys* → **Add API key** → `wsc-rest-api-key`

> ⚠️ API Key는 **Usage Plan + Stage 에 연결되어야만** 동작한다. 키만 만들면 계속 403이 뜬다.

---

## 4.5 prod 스테이지 배포

1. *Resources* → 우상단 **Deploy API**
2. Stage: **New stage** → Stage name `prod` → **Deploy**
3. 배포 후 **Invoke URL** 복사
   `https://<api-id>.execute-api.us-east-1.amazonaws.com/prod`

**③ 채점 포인트** — 4-1-A
```
wsc-rest-api
prod
```

> ⚠️ 리소스나 메서드를 **수정할 때마다 반드시 다시 Deploy** 해야 반영된다. 가장 흔한 실수.

---

## 4.6 CloudShell에서 최종 검증 (4-2 ~ 4-6 재현)

```bash
aws configure set default.region us-east-1

API_URL=$(aws apigateway get-rest-apis \
  --query 'items[?name==`wsc-rest-api`].id' --output text)
API_KEY=$(aws apigateway get-api-keys --include-values \
  --query 'items[?name==`wsc-rest-api-key`].value' --output text)
BASE="https://$API_URL.execute-api.us-east-1.amazonaws.com/prod"

# 4-2  헬스체크 (API Key 불필요)
curl -s $BASE/v1/healthcheck
# → {"status":"ok"}

# 4-3  생성 + 조회 (기존 데이터 정리 후)
aws dynamodb scan --table-name wsc-rest-table --projection-expression "#n" \
  --expression-attribute-names '{"#n":"name"}' | jq -c '.Items[]' \
| while read item; do
    aws dynamodb delete-item --table-name wsc-rest-table --key "$item" > /dev/null
  done

curl -s -X POST $BASE/v1/user \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"name": "kim", "age": 19, "country": "korea"}'
# → {"message": "User created successfully"}

curl -s "$BASE/v1/user?name=kim&age=19" -H "x-api-key: $API_KEY"
# → {"name": "kim", "country": "korea", "age": 19}

# 4-4  중복 저장 방지 / 없는 사용자
curl -s -X POST $BASE/v1/user \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"name": "kim", "age": 19, "country": "korea"}'
# → {"message": "User already exists"}

curl -s "$BASE/v1/user?name=nobody&age=19" -H "x-api-key: $API_KEY"
# → {"message": "User not found"}

# 4-5  API Key 없이 호출 → 차단
curl -s -X POST $BASE/v1/user \
  -H "Content-Type: application/json" \
  -d '{"name": "kim", "age": 19, "country": "korea"}'
# → {"message":"Forbidden"}

# 4-6  필수 쿼리스트링 누락 → API GW 단에서 차단
curl -s "$BASE/v1/user?name=nobody" -H "x-api-key: $API_KEY"
# → {"message": "Missing required request parameters: [age]"}
```

---
---

# 🏁 마무리 자체점검

## 제출 전 최종 확인

```
[ ] 모듈1 Bastion(ap-northeast-2) SSH 접속 OK, kubectl/jq 설치됨
[ ] 모듈2 Bastion(ap-southeast-1) SSH 패스워드 Skill53## 접속 OK, jq 설치됨
[ ] 모듈3 Bastion(ap-northeast-1) SSH 접속 OK, kubectl/helm/jq 설치됨 + SSM 등록됨
[ ] 세 Bastion 모두 EIP 로 IP 고정
[ ] 세 Bastion 모두 Admin 권한 IAM Role 부착
[ ] CloudShell 에서 aws apigateway 명령 동작 (모듈4)
[ ] 모든 SG 아웃바운드 80/443 anyopen
[ ] 모든 리소스 Name 태그 오탈자 확인
```

## 자주 나오는 실패 원인 TOP 8

| # | 증상 | 원인 / 해결 |
|---|---|---|
| 1 | 1-3-A 가 `2 3 10` | NodeGroup **Desired가 3**. → 2로 |
| 2 | 1-6 Pod 안 늘어남 | KEDA가 SQS 못 읽음 → IRSA + `identityOwner: operator` |
| 3 | 1-6 Node 안 늘어남 | 서브넷/SG에 `karpenter.sh/discovery` 태그 누락 |
| 4 | 2-6 curl 타임아웃 | App SG에 **vpc-lattice prefix list** 인바운드 8080 누락 |
| 5 | 2-5-A Header=default | 헤더 매칭을 **Exact** 가 아닌 Prefix로 만듦 |
| 6 | 3-2-A LoadBalancer 없음 | public 서브넷에 `kubernetes.io/role/elb=1` 태그 누락 |
| 7 | 3-4-A `active` 안 나옴 | EC2에 SSM Role 없음 / 아웃바운드 443 막힘 |
| 8 | 4-x 계속 403 | API Key가 **Usage Plan + prod stage** 에 연결 안 됨 |

## 리전 최종 확인 (제일 자주 틀림)

```bash
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=wsc-scaling-vpc --query 'Vpcs[].VpcId'
aws ec2 describe-vpcs --region ap-southeast-1 --filters Name=tag:Name,Values=wsc-hub-vpc     --query 'Vpcs[].VpcId'
aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=wsc-logging-vpc --query 'Vpcs[].VpcId'
aws dynamodb list-tables --region us-east-1 --query "TableNames[?@=='wsc-rest-table']"
```
네 줄 모두 값이 나와야 정상.
