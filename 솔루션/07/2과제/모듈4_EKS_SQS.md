# 모듈 4 — Event-driven Pod Scaling with AWS SQS (콘솔 + kubectl)

**리전: 오레곤 `us-west-2`** — 리전 선택기 먼저 오레곤으로!

> 이 모듈은 EKS·Fargate·IRSA 까지는 **콘솔**로, KEDA/Karpenter/Worker(쿠버네티스 오브젝트)는
> **kubectl/helm**(CloudShell)으로 마무리합니다. 콘솔만으로는 K8s 리소스를 못 만듭니다.
>
> ⏱ EKS 클러스터 생성에만 15~20분 → **가장 먼저 시작**하세요.

## 목표 흐름

```
SQS(skills-sqs-queue) 메시지 증가
   ▼ KEDA(ScaledObject) 가 큐 길이 감지
sqs-worker Deployment 스케일 아웃 (0→N)
   ▼ Pod 가 Karpenter NodePool 요구
Karpenter 가 EC2 Worker Node 동적 생성 → Pod 스케줄 → 메시지 처리
```

## 고정 이름 요약

| 항목 | 값 |
|------|-----|
| EKS Cluster | `skills-sqs-cluster` |
| Fargate Profiles | `skills-sqs-fp-keda`(ns keda), `skills-sqs-fp-karpenter`(ns karpenter) |
| SQS Queue | `skills-sqs-queue` (Standard, visibility ≥30) |
| Namespaces | `keda`, `karpenter`, `skills-sqs` |
| ServiceAccounts (IRSA) | `keda/keda-operator`, `karpenter/karpenter`, `skills-sqs/sqs-worker-sa` |
| Deployment | `sqs-worker` (label app=sqs-worker) |
| ScaledObject / TriggerAuth | `sqs-worker-scaledobject` / `sqs-worker-trigger-auth` |
| NodePool / EC2NodeClass | `skills-sqs-nodepool` / `skills-sqs-nodeclass` |
| NodePool Label | `skills-nodepool=event-worker` |

---

## 1단계. 네트워크(VPC)

`[VPC > VPC 생성]` — "VPC 등"
- 이름: `skills-sqs`, CIDR `10.4.0.0/16`, DNS 호스트네임 ON
- AZ 2개, **퍼블릭 서브넷 2 + 프라이빗 서브넷 2**
- **NAT 게이트웨이: 1개(In 1 AZ)** ← 프라이빗(Fargate/노드)의 아웃바운드에 필요
- 생성 후 **프라이빗 서브넷 2개**에 태그 추가:
  - `[VPC > 서브넷 > 태그]` : Key `kubernetes.io/cluster/skills-sqs-cluster` = `owned`

---

## 2단계. IAM 역할 (클러스터 / Fargate / 노드)

`[IAM > 역할 > 생성]`

**① 클러스터 역할** `skills-sqs-eks-cluster-role`
- 신뢰: **EKS - Cluster** (`eks.amazonaws.com`)
- 정책: `AmazonEKSClusterPolicy`

**② Fargate 실행 역할** `skills-sqs-fargate-role`
- 신뢰: `eks-fargate-pods.amazonaws.com`
- 정책: `AmazonEKSFargatePodExecutionRolePolicy`

**③ Karpenter 노드 역할** `skills-sqs-node-role`
- 신뢰: **EC2** (`ec2.amazonaws.com`)
- 정책 4개: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
  `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`
- 이 역할로 **인스턴스 프로파일** `skills-sqs-node-profile` 생성
  (콘솔에서 EC2 역할을 만들면 동명 인스턴스 프로파일이 자동 생성됨)

---

## 3단계. EKS 클러스터 생성 (콘솔)

`[EKS > 클러스터 추가 > 생성]`
- 이름: **`skills-sqs-cluster`**
- 쿠버네티스 버전: 최신 기본
- 클러스터 서비스 역할: `skills-sqs-eks-cluster-role`
- 네트워킹: VPC `skills-sqs`, **퍼블릭+프라이빗 서브넷 모두** 선택
- 클러스터 엔드포인트 액세스: **퍼블릭 및 프라이빗**
- **인증 모드: EKS API 및 ConfigMap** (`API_AND_CONFIG_MAP`)
- 생성 → **약 15분 대기** (ACTIVE 될 때까지)

### 3-1. 본인(및 CloudShell) 접근 권한 부여 — 매우 중요
`[EKS > skills-sqs-cluster > 액세스 > IAM 액세스 항목 > 액세스 항목 생성]`
- IAM 주체: **CloudShell/채점에 쓸 IAM User 또는 Role ARN**
- 정책 연결: **AmazonEKSClusterAdminPolicy**, 범위 **cluster**
- 생성
> 이걸 안 하면 kubectl 이 `401 the server has asked for the client to provide credentials` 로 막힙니다.

---

## 4단계. Fargate 프로파일 3개

`[EKS > skills-sqs-cluster > 컴퓨팅 > Fargate 프로파일 추가]` (각각 생성, Pod 실행 역할 = `skills-sqs-fargate-role`, 서브넷 = **프라이빗 2개**)

| 프로파일 이름 | 네임스페이스 |
|---------------|--------------|
| `skills-sqs-fp-kube-system` | `kube-system` |
| `skills-sqs-fp-keda` | `keda` |
| `skills-sqs-fp-karpenter` | `karpenter` |

> `kube-system` 프로파일은 **CoreDNS 를 Fargate 에서 돌리기 위해** 필요합니다(아래 6단계).

---

## 5단계. SQS 큐

`[SQS > 대기열 생성]`
- 유형: **표준(Standard)**
- 이름: **`skills-sqs-queue`**
- **제한 시간 제한(Visibility timeout): 30초 이상**
- 생성

---

## 6단계. OIDC 공급자 + IRSA 역할 3개

### 6-1. OIDC 공급자 등록
`[EKS > skills-sqs-cluster > 개요]` 에서 **OpenID Connect 공급자 URL** 복사 →
`[IAM > 자격 증명 공급자 > 공급자 추가]`
- 유형: **OpenID Connect**
- 공급자 URL: 위 URL 붙여넣고 **지문 가져오기**
- 대상: `sts.amazonaws.com`
- 추가

> 또는 CloudShell 한 줄: `eksctl utils associate-iam-oidc-provider --cluster skills-sqs-cluster --region us-west-2 --approve`

### 6-2. IRSA 역할 (신뢰 정책에 OIDC sub 조건)
아래 3개 역할을 만듭니다. 신뢰 정책의 `<OIDC>` 는 위 공급자 경로(예:
`oidc.eks.us-west-2.amazonaws.com/id/XXXX`).

**① `skills-sqs-keda-role`** — SA `keda:keda-operator`
- 권한: SQS 조회
```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["sqs:GetQueueAttributes","sqs:GetQueueUrl"],"Resource":"<skills-sqs-queue ARN>"}]}
```
- 신뢰:
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Federated":"arn:aws:iam::<ACCT>:oidc-provider/<OIDC>"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{"<OIDC>:sub":"system:serviceaccount:keda:keda-operator"}}}]}
```

**② `skills-sqs-karpenter-role`** — SA `karpenter:karpenter`
- 정책 첨부: `AmazonEC2FullAccess`, `AmazonSSMReadOnlyAccess`, `AmazonEKSWorkerNodePolicy`
- 인라인 추가:
```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["eks:DescribeCluster"],"Resource":"<cluster ARN>"},
  {"Effect":"Allow","Action":["iam:PassRole","iam:GetInstanceProfile","iam:CreateInstanceProfile","iam:DeleteInstanceProfile","iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:TagInstanceProfile"],"Resource":"*"},
  {"Effect":"Allow","Action":["pricing:*","ec2:*","ssm:GetParameter"],"Resource":"*"}]}
```
- 신뢰 sub: `system:serviceaccount:karpenter:karpenter`

**③ `skills-sqs-worker-role`** — SA `skills-sqs:sqs-worker-sa`
- 정책: `sqs:*` on `<skills-sqs-queue ARN>`
- 신뢰 sub: `system:serviceaccount:skills-sqs:sqs-worker-sa`

### 6-3. Karpenter 노드 역할을 클러스터에 등록
`[EKS > 액세스 > 액세스 항목 생성]`
- 주체: `skills-sqs-node-role`, 유형 **EC2_Linux**

---

## 7단계. kubectl / helm 준비 (CloudShell)

```bash
aws eks update-kubeconfig --region us-west-2 --name skills-sqs-cluster

# CoreDNS 를 Fargate 에서 돌리도록 패치 (필수! 안 하면 클러스터 DNS 죽음)
kubectl patch deployment coredns -n kube-system --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]'
kubectl rollout restart deployment coredns -n kube-system
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide   # Fargate 에서 Running 확인

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 네임스페이스
kubectl create namespace keda
kubectl create namespace karpenter
kubectl create namespace skills-sqs
```

> **CoreDNS 패치를 빼먹으면** KEDA/Karpenter 가 `sts...:53 connection refused` 로 전부 실패합니다.
> 이 모듈에서 제일 자주 막히는 지점입니다.

---

## 8단계. KEDA 설치

```bash
KEDA_ROLE=$(aws iam get-role --role-name skills-sqs-keda-role --query Role.Arn --output text)
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm upgrade --install keda kedacore/keda --namespace keda \
  --set serviceAccount.operator.annotations."eks\.amazonaws\.com/role-arn"="$KEDA_ROLE"
```

---

## 9단계. Karpenter 설치

```bash
KARP_ROLE=$(aws iam get-role --role-name skills-sqs-karpenter-role --query Role.Arn --output text)
ENDPOINT=$(aws eks describe-cluster --name skills-sqs-cluster --region us-west-2 --query cluster.endpoint --output text)
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.4.0 --namespace karpenter \
  --set "settings.clusterName=skills-sqs-cluster" \
  --set "settings.clusterEndpoint=$ENDPOINT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARP_ROLE" \
  --set replicas=1
```

---

## 10단계. Worker 이미지 빌드 & 푸시 (ECR)

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws ecr create-repository --repository-name skills-sqs-worker --region us-west-2 2>/dev/null || true
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com

# 제공 worker.py + Dockerfile 이 있는 폴더에서
docker build -t skills-sqs-worker .
docker tag skills-sqs-worker:latest ${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com/skills-sqs-worker:latest
docker push ${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com/skills-sqs-worker:latest
```

---

## 11단계. 쿠버네티스 오브젝트 적용

아래 값을 채워 `kubectl apply -f -` 로 적용합니다.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
WORKER_ROLE=$(aws iam get-role --role-name skills-sqs-worker-role --query Role.Arn --output text)
SQS_URL=$(aws sqs get-queue-url --region us-west-2 --queue-name skills-sqs-queue --query QueueUrl --output text)
```

### Worker ServiceAccount + Deployment
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sqs-worker-sa
  namespace: skills-sqs
  annotations:
    eks.amazonaws.com/role-arn: "$WORKER_ROLE"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqs-worker
  namespace: skills-sqs
spec:
  replicas: 0
  selector:
    matchLabels: { app: sqs-worker }
  template:
    metadata:
      labels: { app: sqs-worker }
    spec:
      serviceAccountName: sqs-worker-sa
      nodeSelector:
        karpenter.sh/nodepool: skills-sqs-nodepool
        skills-nodepool: event-worker
      containers:
      - name: worker
        image: ${ACCOUNT}.dkr.ecr.us-west-2.amazonaws.com/skills-sqs-worker:latest
        env:
        - { name: SQS_QUEUE_URL, value: "$SQS_URL" }
        - { name: AWS_REGION, value: "us-west-2" }
        - { name: PROCESSING_SECONDS, value: "5" }
EOF
```

### KEDA TriggerAuthentication + ScaledObject
```bash
cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata: { name: sqs-worker-trigger-auth, namespace: skills-sqs }
spec:
  podIdentity: { provider: aws }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: sqs-worker-scaledobject, namespace: skills-sqs }
spec:
  scaleTargetRef: { name: sqs-worker }
  pollingInterval: 15
  cooldownPeriod: 30
  minReplicaCount: 0
  maxReplicaCount: 6
  triggers:
  - type: aws-sqs-queue
    authenticationRef: { name: sqs-worker-trigger-auth }
    metadata:
      queueURL: "$SQS_URL"
      queueLength: "2"
      awsRegion: "us-west-2"
EOF
```

### Karpenter NodePool + EC2NodeClass
```bash
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: skills-sqs-nodepool }
spec:
  template:
    metadata:
      labels: { skills-nodepool: event-worker }
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: skills-sqs-nodeclass }
      requirements:
      - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
      - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
      - { key: node.kubernetes.io/instance-type, operator: In, values: ["t3.medium","t3.large"] }
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits: { cpu: 100 }
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata: { name: skills-sqs-nodeclass }
spec:
  amiSelectorTerms: [{ alias: al2023@latest }]
  role: "skills-sqs-node-role"
  subnetSelectorTerms: [{ tags: { kubernetes.io/cluster/skills-sqs-cluster: owned } }]
  securityGroupSelectorTerms: [{ tags: { kubernetes.io/cluster/skills-sqs-cluster: owned } }]
EOF
```

> EC2NodeClass 가 서브넷/보안그룹을 태그로 찾습니다.
> - 프라이빗 서브넷 태그(1단계)와,
> - 클러스터 보안 그룹 태그: `[EC2 > 보안그룹]` 에서 `eks-cluster-sg-skills-sqs-cluster-*` 에
>   `kubernetes.io/cluster/skills-sqs-cluster=owned` 태그 추가.

---

## 12단계. 스케일 아웃 검증

```bash
SQS_URL=$(aws sqs get-queue-url --region us-west-2 --queue-name skills-sqs-queue --query QueueUrl --output text)
for i in $(seq 1 12); do aws sqs send-message --region us-west-2 --queue-url "$SQS_URL" --message-body "judge-$i"; done

# 180초 내: Pod 증가 + Karpenter EC2 노드 생성 + 큐 감소
watch -n5 'kubectl get pods -n skills-sqs -l app=sqs-worker -o wide; \
  kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool'
```

기대: `sqs-worker` 가 6개까지 뜨고, `skills-sqs-nodepool-xxxx` EC2 노드가 새로 생겨
Pod 들이 **Fargate 가 아닌 그 EC2 노드**에 스케줄, 큐가 0으로 감소.

## 체크리스트
- [ ] 클러스터 ACTIVE + Fargate 프로파일 keda/karpenter ACTIVE + kubectl 접근
- [ ] SQS 표준 + 3개 SA 에 IRSA role-arn annotation
- [ ] **CoreDNS Fargate 패치 완료** (안 하면 전부 실패)
- [ ] KEDA/Karpenter 컨트롤러 Running
- [ ] Worker Deployment/env/nodeSelector + ScaledObject/TriggerAuth
- [ ] NodePool/EC2NodeClass + Worker Pod 가 Karpenter EC2 노드에 배치
- [ ] 메시지 12개 → 180초 내 스케일아웃 & 큐 드레인

## 자주 막히는 곳
1. **kubectl 401** → 3-1 액세스 항목(본인 ARN + ClusterAdmin) 확인
2. **KEDA/Karpenter STS lookup 실패** → 7단계 CoreDNS 패치 안 함
3. **Karpenter 1/2 CrashLoop** → `--set replicas=1` (9단계에 이미 반영)
4. **Pod Pending** → 서브넷/보안그룹 태그(`kubernetes.io/cluster/...=owned`) 누락
