# 모듈 1 — EKS Scaling (콘솔 가이드)

**리전: ap-northeast-2 (서울)** — 우측 상단에서 반드시 서울로 변경

> 목표: EKS 클러스터에 앱을 배포하고, **KEDA**(SQS 큐 기반 Pod 스케일)와 **Karpenter**(노드 자동 프로비저닝)를 구성.
> 순수 콘솔로 안 되는 부분(KEDA/Karpenter/매니페스트)은 **CloudShell 또는 bastion에서 kubectl/helm**으로 한다.

## 목표 리소스 이름
| 항목 | 이름 |
|------|------|
| EKS Cluster | `wsi-eks` |
| System NodeGroup | `wsi-system` (t3.medium, 2/2/2, taint `dedicated=addon:NoSchedule`) |
| SQS Queue | `wsi-task-queue` |
| Namespace / Deployment / SA | `wsi-app` / `wsi-worker-app` / `wsi-worker-sa` |
| ScaledObject | `wsi-keda-scaler` (SQS, min 0 / max 20) |
| NodePool / EC2NodeClass | `wsi-nodepool` (c5) / `wsi-nodeclass` |

---

## 1. VPC 만들기

**VPC 콘솔 → VPC 생성 → "VPC 등 여러 리소스"** 선택 (한 번에 서브넷/NAT/IGW 생성)

- 이름 태그 자동 생성: `wsi`
- IPv4 CIDR: `10.0.0.0/16`
- AZ 수: **2** (ap-northeast-2a, 2c)
- 퍼블릭 서브넷 수: 2
- 프라이빗 서브넷 수: 2
- NAT 게이트웨이: **1개 AZ에** (비용 절감) 또는 AZ당 1개
- VPC 엔드포인트: 없음
- **생성**

생성 후 서브넷 태그 추가 (EKS/Karpenter가 서브넷 자동 발견에 사용):
- 퍼블릭 서브넷 2개 → 태그 `kubernetes.io/role/elb` = `1`
- 프라이빗 서브넷 2개 → 태그:
  - `kubernetes.io/role/internal-elb` = `1`
  - **`karpenter.sh/discovery` = `wsi-eks`** ← Karpenter 필수
- 모든 서브넷 → `kubernetes.io/cluster/wsi-eks` = `shared`

---

## 2. SQS 큐 만들기

**SQS 콘솔 → 대기열 생성**
- 유형: 표준
- 이름: `wsi-task-queue`
- 나머지 기본 → **생성**
- 생성 후 **URL**과 **ARN** 메모 (나중에 IRSA 정책 / ScaledObject에 사용)

---

## 3. EKS 클러스터 IAM 역할

**IAM 콘솔 → 역할 → 역할 생성**
- 신뢰 엔터티: AWS 서비스 → **EKS → EKS - Cluster**
- 정책: `AmazonEKSClusterPolicy` (자동)
- 이름: `wsi-eks-cluster-role` → 생성

## 4. EKS 클러스터 생성

**EKS 콘솔 → 클러스터 추가 → 생성**
- 이름: `wsi-eks`
- Kubernetes 버전: `1.31`
- 클러스터 서비스 역할: `wsi-eks-cluster-role`
- **인증 모드: EKS API 및 ConfigMap** (`API_AND_CONFIG_MAP`)
- 다음:
  - VPC: `wsi` VPC
  - 서브넷: 퍼블릭 2 + 프라이빗 2 모두 선택
  - 클러스터 엔드포인트 액세스: **퍼블릭 및 프라이빗**
- 나머지 기본 → **생성** (약 10분 소요)

> 생성되는 동안 5~8번 병행 가능.

---

## 5. 노드그룹 IAM 역할

**IAM → 역할 생성** → AWS 서비스 → **EC2**
- 정책 3개 연결: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`
- 이름: `wsi-system-ng-role` → 생성

## 6. System 노드그룹 생성

클러스터 ACTIVE 후 → **EKS → wsi-eks → 컴퓨팅 → 노드 그룹 추가**
- 이름: `wsi-system`
- 노드 IAM 역할: `wsi-system-ng-role`
- 다음:
  - AMI: Amazon Linux 2023
  - 인스턴스 유형: `t3.medium`
  - 디스크 20GB
  - 스케일링: **최소 2 / 최대 2 / 원하는 크기 2**
- 다음:
  - 서브넷: **프라이빗 서브넷 2개만** 선택
- 생성

**Taint 추가** (앱 Pod가 이 노드 회피 → Karpenter 노드로 가게):
- 노드그룹 `wsi-system` → 편집 → **Kubernetes taints** 추가
  - Key `dedicated`, Value `addon`, Effect `NoSchedule`
- 저장

---

## 7. Karpenter 노드용 IAM 역할

**IAM → 역할 생성** → EC2
- 정책 4개: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`
- 이름: `wsi-karpenter-node-role` → 생성
- (인스턴스 프로파일은 역할 생성 시 자동)

**EKS 액세스 항목 추가** (Karpenter 노드가 클러스터 조인):
- EKS → wsi-eks → 액세스 → **액세스 항목 생성**
- IAM 보안 주체: `wsi-karpenter-node-role` ARN
- 유형: **EC2 Linux** → 생성

---

## 8. bastion EC2 (private 클러스터 접근용)

**EC2 콘솔 → 인스턴스 시작**
- 이름: `wsi-bastion`
- AMI: Amazon Linux 2023
- 유형: t3.micro
- 서브넷: 퍼블릭 서브넷, 퍼블릭 IP 자동 할당 **활성화**
- IAM 인스턴스 프로파일: 아래 역할 생성 후 지정
  - IAM 역할 `wsi-bastion-role` 생성 (EC2 신뢰) → `AdministratorAccess` + `AmazonSSMManagedInstanceCore` 연결
- 시작

**bastion을 클러스터 admin으로** (kubectl 권한):
- EKS → wsi-eks → 액세스 → 액세스 항목 생성 → `wsi-bastion-role` ARN, 유형 Standard
- → 정책 연결: **AmazonEKSClusterAdminPolicy**, 범위 cluster

---

## 9. IRSA용 OIDC 공급자

- EKS → wsi-eks → **개요** 탭 → **OpenID Connect 공급자 URL** 복사
- IAM → 자격 증명 공급자 → **공급자 추가** → OpenID Connect
  - 공급자 URL: 위 URL 붙여넣고 **지문 가져오기**
  - 대상: `sts.amazonaws.com` → 추가

## 10. IRSA 역할 3개 (app / KEDA / Karpenter)

각각 IAM → 역할 생성 → **웹 자격 증명** → 방금 만든 OIDC 공급자, Audience `sts.amazonaws.com`.
역할 생성 후 **신뢰 관계 편집**에서 아래 형태로 `sub` Condition을 추가한다 (`<OIDC>`는 공급자 URL에서 `https://` 뗀 값, `<ACCOUNT>`는 계정 ID).

**(a) 앱 워커 역할 `wsi-worker-role`** — SQS 송수신
신뢰 정책:
```json
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/<OIDC>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringEquals": {
    "<OIDC>:sub": "system:serviceaccount:wsi-app:wsi-worker-sa",
    "<OIDC>:aud": "sts.amazonaws.com" } } }] }
```
권한 정책 (`<QUEUE_ARN>` = wsi-task-queue ARN):
```json
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Action": ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
  "Resource": "<QUEUE_ARN>" }] }
```

**(b) KEDA 역할 `wsi-keda-operator-role`** — SQS 메트릭 조회
- 신뢰 정책: (a)와 동일하되 `sub` = `system:serviceaccount:keda:keda-operator`
- 권한 정책:
```json
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Action": ["sqs:GetQueueAttributes","sqs:GetQueueUrl"],
  "Resource": "<QUEUE_ARN>" }] }
```

**(c) Karpenter 컨트롤러 역할 `wsi-karpenter-controller-role`**
- 신뢰 정책: (a)와 동일하되 `sub` = `system:serviceaccount:kube-system:karpenter`
- 권한 정책:
```json
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Resource": "*", "Action": [
      "ec2:CreateLaunchTemplate","ec2:CreateFleet","ec2:RunInstances","ec2:CreateTags",
      "ec2:TerminateInstances","ec2:DeleteLaunchTemplate",
      "ec2:DescribeLaunchTemplates","ec2:DescribeInstances","ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets","ec2:DescribeImages","ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings","ec2:DescribeAvailabilityZones",
      "ec2:DescribeSpotPriceHistory","pricing:GetProducts" ] },
  { "Effect": "Allow", "Resource": "*", "Action": [
      "iam:PassRole","iam:CreateInstanceProfile","iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile","iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile" ] },
  { "Effect": "Allow", "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:ap-northeast-2:<ACCOUNT>:cluster/wsi-eks" },
  { "Effect": "Allow", "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:ap-northeast-2::parameter/aws/service/eks/optimized-ami/*" }
]}
```

> `<OIDC>`, `<ACCOUNT>`, `<QUEUE_ARN>` 은 실제 값으로 치환. Audience(`aud`) Condition은 웹 자격증명 역할 생성 시 자동으로 들어가 있으니 `sub`만 추가하면 된다.

---

## 11. CloudShell 또는 bastion에서 kubectl 연결

CloudShell(서울 리전) 열거나 bastion에 SSM 접속 후:
```bash
aws eks update-kubeconfig --name wsi-eks --region ap-northeast-2
kubectl get nodes   # system 노드 2개 Ready
```

## 12. KEDA 설치 (helm)
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update

KEDA_ROLE=$(aws iam get-role --role-name wsi-keda-operator-role --query Role.Arn --output text)
helm install keda kedacore/keda -n keda --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KEDA_ROLE" \
  --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule"
```

## 13. Karpenter 설치 (helm)
```bash
KARP_ROLE=$(aws iam get-role --role-name wsi-karpenter-controller-role --query Role.Arn --output text)
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name wsi-eks --query "cluster.endpoint" --output text)

helm install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system \
  --set "settings.clusterName=wsi-eks" \
  --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARP_ROLE" \
  --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule"
```

## 14. 앱 매니페스트 배포 (kubectl)

`app.py`(배포파일)를 ConfigMap으로 넣고 python:3.11-slim에서 실행:
```bash
kubectl create namespace wsi-app

# app.py 를 ConfigMap 으로 (배포파일 app.py 를 현재 디렉토리에 둔 상태)
kubectl create configmap wsi-worker-code -n wsi-app --from-file=app.py

# ServiceAccount (IRSA)
APP_ROLE=$(aws iam get-role --role-name wsi-worker-role --query Role.Arn --output text)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wsi-worker-sa
  namespace: wsi-app
  annotations:
    eks.amazonaws.com/role-arn: "$APP_ROLE"
EOF

# Deployment (python:3.11-slim, /app/app.py, boto3 설치)
QURL=$(aws sqs get-queue-url --queue-name wsi-task-queue --query QueueUrl --output text)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: wsi-worker-app, namespace: wsi-app }
spec:
  replicas: 0
  selector: { matchLabels: { app: wsi-worker-app } }
  template:
    metadata: { labels: { app: wsi-worker-app } }
    spec:
      serviceAccountName: wsi-worker-sa
      containers:
      - name: worker
        image: python:3.11-slim
        command: ["sh","-c","pip install --no-cache-dir --quiet boto3 && python /app/app.py"]
        env:
        - { name: QUEUE_URL, value: "$QURL" }
        - { name: AWS_REGION, value: "ap-northeast-2" }
        resources:
          requests: { cpu: "200m", memory: "128Mi" }
          limits: { cpu: "500m", memory: "256Mi" }
        volumeMounts: [{ name: app-code, mountPath: /app }]
      volumes: [{ name: app-code, configMap: { name: wsi-worker-code } }]
EOF
```

## 15. KEDA ScaledObject (SQS)
```bash
QURL=$(aws sqs get-queue-url --queue-name wsi-task-queue --query QueueUrl --output text)
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: wsi-keda-scaler, namespace: wsi-app }
spec:
  scaleTargetRef: { name: wsi-worker-app }
  minReplicaCount: 0
  maxReplicaCount: 20
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: "$QURL"
      queueLength: "1"
      awsRegion: "ap-northeast-2"
      identityOwner: operator      # ★ IRSA로 SQS 조회 (없으면 awsAccessKeyID not found 에러)
EOF
```

## 16. Karpenter NodePool / EC2NodeClass (c5)
```bash
kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata: { name: wsi-nodeclass }
spec:
  role: "wsi-karpenter-node-role"
  amiSelectorTerms: [{ alias: al2023@latest }]
  subnetSelectorTerms: [{ tags: { karpenter.sh/discovery: "wsi-eks" } }]
  securityGroupSelectorTerms:
  - id: "$(aws eks describe-cluster --name wsi-eks --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: wsi-nodepool }
spec:
  template:
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: wsi-nodeclass }
      requirements:
      - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["c5"] }
      - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
  limits: { cpu: "100" }
  disruption: { consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: 30s }
EOF
```

---

## 17. 동작 확인 (스케일아웃 테스트)
```bash
QURL=$(aws sqs get-queue-url --queue-name wsi-task-queue --query QueueUrl --output text)
for i in $(seq 1 200); do aws sqs send-message --queue-url $QURL --message-body "t-$i" >/dev/null; done

# 3분 이내 replicas 15+ & Karpenter 노드 1+ 이어야 채점 통과
kubectl get deploy wsi-worker-app -n wsi-app
kubectl get nodes -l karpenter.sh/nodepool=wsi-nodepool
kubectl get pods -n wsi-app | head    # Running (CrashLoop 아님)
```

## 자주 나는 오류
- **ScaledObject READY=False, `awsAccessKeyID not found`** → ScaledObject에 `identityOwner: operator` 빠짐 (15단계)
- **파드 CrashLoopBackOff** → app.py ConfigMap 안 붙음 or boto3 미설치 (14단계 command 확인)
- **Karpenter 노드 안 뜸** → 프라이빗 서브넷에 `karpenter.sh/discovery=wsi-eks` 태그 없음 (1단계) 또는 노드 역할 액세스 항목 없음 (7단계)
- **kubectl i/o timeout** → private 클러스터를 VPC 밖에서 접근. CloudShell(VPC 환경) 또는 bastion에서 실행
