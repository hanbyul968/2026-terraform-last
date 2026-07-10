# 모듈 3 — EKS Scaling (콘솔 + CloudShell 솔루션)

**리전: `ap-northeast-2` (서울)**

SQS 메시지 수 기반 **KEDA Pod 오토스케일링** + **Karpenter 노드 오토스케일링**.

> EKS/IAM/SQS/ECR/VPC 는 **콘솔**로, KEDA·Karpenter·워크로드(helm/kubectl)는
> **CloudShell(ap-northeast-2)** 로 진행합니다. (pure 콘솔로는 helm/kubectl 불가)

## 만들 리소스 요약
| 리소스 | 이름 | 설정 |
|--------|------|------|
| SQS | `skm-order-queue` | Standard |
| EKS | `skm-eks-cluster` | v1.35 |
| NodeGroup | `skm-cluster-addon-ng` | t3.medium, 1/1/1, taint dedicated=addon:NoSchedule |
| ECR | `skm-order-processor` | 이미지 저장소 |
| Karpenter | NodePool `skm-app-nodepool` / NodeClass `skm-app-nodeclass` | t3.small,t3.medium |
| KEDA | ScaledObject `order-scaler` | min1/max5, queueLength 5 |

---

## 1. SQS 큐

콘솔 → **SQS** → **대기열 생성**
1. **유형**: **표준(Standard)**
2. **이름**: `skm-order-queue`
3. 나머지 기본 → **대기열 생성**.

---

## 2. VPC (2개 퍼블릭 서브넷)

콘솔 → **VPC** → **VPC 생성** → **VPC 등 여러 리소스**
1. 이름 `skm`, CIDR `10.0.0.0/16`
2. 가용영역 **2개** (ap-northeast-2a, 2c), 퍼블릭 서브넷 2개, 프라이빗 0개
3. NAT 게이트웨이 없음, IGW 포함 → 생성.
4. 두 퍼블릭 서브넷에 **태그 추가** (서브넷 → 태그 편집):
   - `kubernetes.io/cluster/skm-eks-cluster` = `shared`
   - `kubernetes.io/role/elb` = `1`

---

## 3. IAM 역할 (콘솔)

### 3-1. EKS 클러스터 역할 `skm-eks-cluster-role`
IAM → 역할 생성 → 신뢰 엔터티 **EKS** → 사용 사례 **EKS - Cluster** →
정책 `AmazonEKSClusterPolicy` 자동 → 이름 `skm-eks-cluster-role`.

### 3-2. 노드 역할 `skm-cluster-addon-ng-role`
IAM → 역할 생성 → **EC2** → 다음 정책 연결:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`
→ 이름 `skm-cluster-addon-ng-role`.

---

## 4. EKS 클러스터 (콘솔)

콘솔 → **EKS** → **클러스터 생성**
1. **이름**: `skm-eks-cluster`
2. **Kubernetes 버전**: **1.35**
3. **클러스터 서비스 역할**: `skm-eks-cluster-role`
4. **인증 모드**: **EKS API 및 ConfigMap** (Access Entry 사용)
5. **네트워킹**: 위 VPC + 퍼블릭 서브넷 2개, 엔드포인트 **퍼블릭/프라이빗**
6. 생성 (약 10분 소요).

### 4-1. 본인 계정에 Cluster Admin 부여 (kubectl 채점용)
클러스터 → **액세스(Access)** 탭 → **액세스 항목 생성**
1. **IAM 주체**: 현재 CloudShell/콘솔에서 쓰는 IAM 사용자/역할 ARN
2. **정책 연결**: `AmazonEKSClusterAdminPolicy`, 범위 **cluster**
3. 생성.

> CloudShell 에서 접속하는 주체와 동일해야 kubectl 이 동작합니다.

---

## 5. Addon NodeGroup (콘솔)

> 노드의 **Name 태그**가 `skm-cluster-addon-ng-node` 여야 채점됩니다.
> 관리형 노드그룹은 태그가 EC2 로 전파되지 않으므로 **시작 템플릿(Launch Template)** 을 씁니다.

### 5-1. 시작 템플릿
콘솔 → **EC2** → **시작 템플릿** → **생성**
1. 이름 `skm-cluster-addon-ng-lt`
2. **리소스 태그**: 인스턴스 & 볼륨에 `Name=skm-cluster-addon-ng-node`
3. (AMI/인스턴스 타입은 비워도 됨 — 노드그룹이 지정)
4. 생성.

### 5-2. 노드 그룹
EKS 클러스터 → **컴퓨팅** → **노드 그룹 추가**
1. **이름**: `skm-cluster-addon-ng`
2. **노드 IAM 역할**: `skm-cluster-addon-ng-role`
3. **시작 템플릿**: `skm-cluster-addon-ng-lt`
4. **인스턴스 유형**: t3.medium
5. **크기**: 최소 1 / 원하는 1 / 최대 1
6. **서브넷**: 퍼블릭 서브넷 2개
7. **테인트(Taints)**: `dedicated` = `addon`, 효과 **NO_SCHEDULE**
   (노드그룹 생성 후 **테인트 편집**에서 추가 가능)
8. 생성.

### 5-3. CoreDNS 애드온에 toleration
EKS → **추가 기능(Add-ons)** → CoreDNS → **구성 값(Configuration values)** 에:
```json
{ "tolerations": [{ "key": "dedicated", "value": "addon", "effect": "NoSchedule" }] }
```

> ✅ 채점 3-2: skm-eks-cluster 1.35 ACTIVE, t3.medium 1 1 1, 노드 Name 태그 skm-cluster-addon-ng-node

---

## 6. ECR + OIDC + IRSA 역할

### 6-1. ECR
콘솔 → **ECR** → **리포지토리 생성** → 이름 `skm-order-processor`.

### 6-2. OIDC 공급자
EKS 클러스터 → **개요** → **OpenID Connect 공급자 URL** 복사 →
IAM → **자격 증명 공급자** → **공급자 추가** → OpenID Connect →
URL 붙여넣기, 대상 `sts.amazonaws.com` → 추가.
(또는 CloudShell: `eksctl utils associate-iam-oidc-provider --cluster skm-eks-cluster --approve`)

### 6-3. IRSA 역할 3개 (IAM → 역할 생성 → 웹 자격 증명 → 위 OIDC 공급자)

**① App: `skm-order-processor-role`** (SA `skillsmkt:order-processor-sa`)
인라인 정책:
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
  "Resource":"arn:aws:sqs:ap-northeast-2:<ACCOUNT_ID>:skm-order-queue"}]}
```
신뢰정책 Condition (`<OIDC>` = 공급자 호스트):
```
"<OIDC>:sub": "system:serviceaccount:skillsmkt:order-processor-sa",
"<OIDC>:aud": "sts.amazonaws.com"
```

**② KEDA: `skm-keda-operator-role`** (SA `keda:keda-operator`)
```json
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["sqs:GetQueueAttributes","sqs:GetQueueUrl"],
  "Resource":"arn:aws:sqs:ap-northeast-2:<ACCOUNT_ID>:skm-order-queue"}]}
```

**③ Karpenter: `skm-karpenter-controller-role`** (SA `kube-system:karpenter`)
```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["ec2:CreateLaunchTemplate","ec2:CreateFleet","ec2:RunInstances",
   "ec2:CreateTags","ec2:TerminateInstances","ec2:DescribeLaunchTemplates","ec2:DescribeInstances",
   "ec2:DescribeSecurityGroups","ec2:DescribeSubnets","ec2:DescribeImages","ec2:DescribeInstanceTypes",
   "ec2:DescribeInstanceTypeOfferings","ec2:DescribeAvailabilityZones","ec2:DeleteLaunchTemplate",
   "ec2:DescribeSpotPriceHistory","pricing:GetProducts"],"Resource":"*"},
  {"Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::<ACCOUNT_ID>:role/skm-cluster-addon-ng-role"},
  {"Effect":"Allow","Action":["iam:CreateInstanceProfile","iam:DeleteInstanceProfile","iam:GetInstanceProfile",
   "iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:TagInstanceProfile"],"Resource":"*"},
  {"Effect":"Allow","Action":["eks:DescribeCluster"],"Resource":"arn:aws:eks:ap-northeast-2:<ACCOUNT_ID>:cluster/skm-eks-cluster"},
  {"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":"arn:aws:ssm:ap-northeast-2::parameter/aws/service/eks/optimized-ami/*"}
]}
```

---

## 7. CloudShell — 이미지 빌드 & KEDA/Karpenter/워크로드 배포

> **CloudShell(ap-northeast-2)** 을 엽니다. CloudShell 에는 docker 가 없으므로
> 이미지 빌드는 **CodeBuild** 또는 **docker 가 있는 EC2/Bastion** 에서 수행해야 합니다.
> 여기서는 간단히 **로컬(docker 있는 환경)** 또는 **Bastion** 에서 빌드/푸시 후,
> CloudShell 로 helm/kubectl 배포하는 흐름을 씁니다.

### 7-1. 앱 이미지 빌드 & 푸시 (docker 있는 환경)
아래 3개 파일을 한 폴더에 저장:

`app.py`:
```python
import os, threading, time
import boto3
from flask import Flask, jsonify

app = Flask(__name__)
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
PROCESSING_TIME = float(os.environ.get("PROCESSING_TIME", "3"))
sqs = boto3.client("sqs", region_name=AWS_REGION)
_processed = 0; _lock = threading.Lock(); _stop = threading.Event()

def _consumer_loop():
    global _processed
    while not _stop.is_set():
        if not SQS_QUEUE_URL:
            time.sleep(1); continue
        try:
            r = sqs.receive_message(QueueUrl=SQS_QUEUE_URL, MaxNumberOfMessages=10, WaitTimeSeconds=20)
        except Exception:
            time.sleep(1); continue
        for m in r.get("Messages", []):
            time.sleep(PROCESSING_TIME)
            try:
                sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])
                with _lock: _processed += 1
            except Exception as e:
                print(f"failed {e}", flush=True)

@app.route("/healthz")
def healthz(): return jsonify({"status": "ok"}), 200

@app.route("/status")
def status():
    with _lock: c = _processed
    return jsonify({"processed": c, "queue_url": SQS_QUEUE_URL}), 200

if __name__ == "__main__":
    threading.Thread(target=_consumer_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=8080)
```
`requirements.txt`:
```
boto3>=1.35.0
flask>=3.0.0
```
`Dockerfile`:
```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
```
빌드/푸시:
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/skm-order-processor
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker build --platform linux/amd64 -t $REPO:latest .
docker push $REPO:latest
```

### 7-2. kubeconfig + KEDA + Karpenter (CloudShell)
```bash
aws eks update-kubeconfig --name skm-eks-cluster --region ap-northeast-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ENDPOINT=$(aws eks describe-cluster --name skm-eks-cluster --region ap-northeast-2 --query cluster.endpoint --output text)

# KEDA
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm upgrade --install keda kedacore/keda -n keda --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::$ACCOUNT:role/skm-keda-operator-role" \
  --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m

# Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system \
  --set "settings.clusterName=skm-eks-cluster" --set "settings.clusterEndpoint=$ENDPOINT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::$ACCOUNT:role/skm-karpenter-controller-role" \
  --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m
```

### 7-3. 매니페스트 적용 (CloudShell)
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
QURL=$(aws sqs get-queue-url --queue-name skm-order-queue --region ap-northeast-2 --query QueueUrl --output text)
IMG=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/skm-order-processor:latest

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: skm-app-nodepool }
spec:
  template:
    spec:
      taints: [{ key: skm-app-nodepool, effect: NoSchedule }]
      requirements:
        - { key: node.kubernetes.io/instance-type, operator: In, values: ["t3.small","t3.medium"] }
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: skm-app-nodeclass }
  disruption: { consolidationPolicy: WhenEmptyOrUnderutilized, consolidateAfter: 60s }
  limits: { cpu: "8", memory: 16Gi }
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata: { name: skm-app-nodeclass }
spec:
  amiSelectorTerms: [{ alias: "al2023@latest" }]
  role: "skm-cluster-addon-ng-role"
  subnetSelectorTerms: [{ tags: { kubernetes.io/cluster/skm-eks-cluster: "*" } }]
  securityGroupSelectorTerms: [{ tags: { kubernetes.io/cluster/skm-eks-cluster: owned } }]
---
apiVersion: v1
kind: Namespace
metadata: { name: skillsmkt }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-processor-sa
  namespace: skillsmkt
  annotations: { eks.amazonaws.com/role-arn: "arn:aws:iam::$ACCOUNT:role/skm-order-processor-role" }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: order-processor, namespace: skillsmkt }
spec:
  replicas: 1
  selector: { matchLabels: { app: order-processor } }
  template:
    metadata: { labels: { app: order-processor } }
    spec:
      serviceAccountName: order-processor-sa
      tolerations: [{ key: skm-app-nodepool, operator: Exists, effect: NoSchedule }]
      nodeSelector: { karpenter.sh/nodepool: skm-app-nodepool }
      containers:
        - name: order-processor
          image: "$IMG"
          ports: [{ containerPort: 8080 }]
          env:
            - { name: AWS_REGION, value: "ap-northeast-2" }
            - { name: SQS_QUEUE_URL, value: "$QURL" }
            - { name: PROCESSING_TIME, value: "3" }
          resources: { requests: { cpu: "500m", memory: "512Mi" } }
          livenessProbe:  { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: order-scaler, namespace: skillsmkt }
spec:
  scaleTargetRef: { name: order-processor }
  minReplicaCount: 1
  maxReplicaCount: 5
  pollingInterval: 10
  cooldownPeriod: 30
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown: { stabilizationWindowSeconds: 0, policies: [{ type: Percent, value: 100, periodSeconds: 15 }] }
  triggers:
    - type: aws-sqs-queue
      metadata: { queueURL: "$QURL", queueLength: "5", awsRegion: "ap-northeast-2", identityOwner: "operator" }
EOF
```

> ✅ 채점 3-3(nodepool/replicas/port/resource/env), 3-4(1 5 aws-sqs-queue 5),
> 3-5(WhenEmptyOrUnderutilized 60s, t3.medium,t3.small, taint 1, nodeclass)

---

## 8. 검증 (Scale-out / Scale-in)

```bash
QURL=$(aws sqs get-queue-url --queue-name skm-order-queue --region ap-northeast-2 --query QueueUrl --output text)

# 3-6 부하 주입 (100건)
for b in $(seq 1 10); do
  E=$(for i in $(seq 1 10); do printf '{"Id":"%d-%d","MessageBody":"order"},' "$b" "$i"; done | sed 's/,$//')
  aws sqs send-message-batch --queue-url "$QURL" --entries "[$E]" --region ap-northeast-2 >/dev/null
done
kubectl get pods -n skillsmkt -w     # Pod 최대 5, 노드 부족 시 Karpenter 노드 추가(≥2)

# 3-7 부하 제거 후 복귀
aws sqs purge-queue --queue-url "$QURL" --region ap-northeast-2
# 최대 3분 후 Pod 1 / Node 1 로 복귀
```

> ✅ 3-6: Max Ready Pods 5, Max App Nodes ≥2 / 3-7: Final Pods 1, Final Nodes 1
> ⚠️ 과제 종료 전 반드시 Pod 1 / Node 1 로 복귀시킬 것.
