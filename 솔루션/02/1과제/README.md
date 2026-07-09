# 🖥️ 제1과제 — AWS 콘솔로 처음부터 끝까지 (과제지_vf)

> **Web Service Provisioning** — EKS 기반 콘서트 예매 API + 정적 웹(S3/CloudFront) + 모니터링
> Terraform 없이 **AWS Management Console + CloudShell** 만으로 구축하는 실전 가이드.

---

## ⚠️ 시작 전 절대 규칙 (5개)

| # | 규칙 |
|---|------|
| 1 | **리전은 항상 서울 `ap-northeast-2`** — 우측 상단에서 고정 |
| 2 | **모든 이름·태그는 대소문자 구분** — 채점 스크립트가 문자열 완전일치로 비교 |
| 3 | `<비번호>` 는 본인 번호로 치환 (예: `103`) |
| 4 | 배포파일(`book`, `index.html`, `main.jpeg`)은 **수정 없이** 사용 |
| 5 | 컨테이너/쿠버네티스 단계는 GUI 불가 → **CloudShell(`>_`)** 사용 |

---

## 📑 목차 & 진행 순서

| 순 | 단계 | 콘솔 서비스 | 채점 |
|----|------|-------------|------|
| [1](#1️⃣-kms--암호화-키-3개) | KMS 키 3개 | KMS | 2-2·4-1·5-1 |
| [2](#2️⃣-vpc--네트워크) | VPC/서브넷/라우팅 | VPC | 1-1·1-2 |
| [3](#3️⃣-s3--정적-웹) | S3 버킷·객체 | S3 | 2-1·2-2 |
| [4](#4️⃣-ecr--컨테이너-이미지) | ECR + 이미지 push | ECR | 3-1 |
| [5](#5️⃣-dynamodb) | DynamoDB | DynamoDB | 4-1 |
| [6](#6️⃣-eks-클러스터) | EKS 클러스터 | EKS | 5-1 |
| [7](#7️⃣-노드그룹-2개) | 노드그룹 ×2 | EKS | 5-2·5-3 |
| [8](#8️⃣-lambda) | Lambda | Lambda | 6-1 |
| [9](#9️⃣-alb--book) | ALB | EC2 | 7-1·7-2 |
| [10](#-cloudfront) | CloudFront | CloudFront | 8-1~8-4 |
| [11](#-애플리케이션-배포-cloudshell) | 앱 배포 | CloudShell | 5-3·9-1 |
| [12](#-모니터링-cloudshell) | 모니터링 | CloudShell | 10-1 |
| [13](#-최종-검증) | 검증 | CloudShell | 전체 |

> ⏱️ EKS 클러스터·노드·CloudFront 배포에 각각 수 분~10분 걸리니, **6번(EKS)을 먼저 생성 걸어두고**
> 그 사이 1~5·8·9 를 진행하면 시간을 아낄 수 있다.

---

## 0️⃣ 사전 준비

1. 콘솔 우측 상단 리전 → **아시아 태평양(서울) ap-northeast-2**.
2. 우측 상단 **CloudShell(`>_`)** 실행 → `aws sts get-caller-identity` 로 계정 확인.
3. CloudShell **Actions → Upload file** 로 `book`, `index.html`, `main.jpeg` 업로드.

---

## 1️⃣ KMS — 암호화 키 3개

> 📍 **KMS → Customer managed keys → Create key** (3번 반복)
> 채점(2-2/4-1/5-1)이 **별칭(Alias)** 을 정확히 비교하므로 이름이 핵심.

각 키 공통: `Key type = Symmetric`, `Key usage = Encrypt and decrypt` → Next →
**Alias** 입력 → Key administrators/users 에 본인 역할 추가 → Finish.

| 만들 키 | Alias (정확히) | 용도 |
|---------|----------------|------|
| 1 | `wskorea26-s3-key` | S3 객체 (+ECR·EBS·Logs 재사용 가능) |
| 2 | `wskorea26-dynamodb-key` | DynamoDB |
| 3 | `wskorea26-eks-key` | EKS Secret |

- ✅ 완료 조건: `aws kms list-aliases` 에 위 3개 별칭이 보이면 OK.

---

## 2️⃣ VPC — 네트워크

> 📍 **VPC → Create VPC → "VPC only"** 선택 (마법사 대신 수동 = 이름 통제)

### 2-1. VPC 생성
- Name `wskorea26-vpc` · IPv4 CIDR **`172.16.0.0/16`** → Create.
- 생성된 VPC 선택 → **Actions → Edit DNS settings** → **DNS hostnames ✅ Enable**.

### 2-2. 서브넷 4개
> 📍 **VPC → Subnets → Create subnet** (VPC = wskorea26-vpc)

| Name | 가용영역 | IPv4 CIDR |
|------|----------|-----------|
| `wskorea26-pub-subnet-c` | ap-northeast-2**c** | `172.16.1.0/24` |
| `wskorea26-pub-subnet-d` | ap-northeast-2**d** | `172.16.2.0/24` |
| `wskorea26-priv-subnet-c` | ap-northeast-2**c** | `172.16.201.0/24` |
| `wskorea26-priv-subnet-d` | ap-northeast-2**d** | `172.16.202.0/24` |

- 두 **pub** 서브넷: 선택 → Actions → **Edit subnet settings → Enable auto-assign public IPv4 ✅**.
- 💡 EKS 자동탐색용 태그(권장): pub 2개 `kubernetes.io/role/elb=1`,
  priv 2개 `kubernetes.io/role/internal-elb=1`, 4개 모두 `kubernetes.io/cluster/wskorea26-cluster=shared`.

### 2-3. 인터넷 게이트웨이
> 📍 **VPC → Internet gateways → Create**
- Name `book-igw` → Create → **Actions → Attach to VPC → wskorea26-vpc**.

### 2-4. NAT 게이트웨이 2개
> 📍 **VPC → NAT gateways → Create** (2번)

| Name | Subnet | Elastic IP |
|------|--------|------------|
| `book-ngw-c` | wskorea26-pub-subnet-c | **Allocate Elastic IP** 클릭 |
| `book-ngw-d` | wskorea26-pub-subnet-d | **Allocate Elastic IP** 클릭 |

### 2-5. 라우팅 테이블 3개
> 📍 **VPC → Route tables → Create route table** (3번, VPC = wskorea26-vpc)

| Name | 경로 (Edit routes) | 연결 서브넷 (Subnet associations) |
|------|--------------------|-----------------------------------|
| `wskorea26-public-rtb` | `0.0.0.0/0 → book-igw` | pub-c, pub-d |
| `wskorea26-private-rtb-c` | `0.0.0.0/0 → book-ngw-c` | priv-c |
| `wskorea26-private-rtb-d` | `0.0.0.0/0 → book-ngw-d` | priv-d |

> 🎯 **채점 1-2**: private RTB 엔 `0.0.0.0/0 = NAT` **하나만**. 불필요한 경로 추가 금지.

---

## 3️⃣ S3 — 정적 웹

> 📍 **S3 → Create bucket**

- Bucket name **`wskorea26-concert-bucket-<비번호>`**, Region 서울.
- **Block all public access = ✅ 켜짐(4개 전부)** 유지.
- Default encryption → **SSE-KMS** → `alias/wskorea26-s3-key` → **Bucket Key: Enable** → Create.

### 3-1. 객체 업로드 (CloudShell — 경로/KMS 정확)
```bash
BUCKET=wskorea26-concert-bucket-<비번호>
aws s3 cp index.html s3://$BUCKET/web/main/index.html \
  --content-type text/html  --sse aws:kms --sse-kms-key-id alias/wskorea26-s3-key
aws s3 cp main.jpeg  s3://$BUCKET/web/main/main.jpeg \
  --content-type image/jpeg --sse aws:kms --sse-kms-key-id alias/wskorea26-s3-key
```
> 🎯 **2-1** 객체 키 = `web/main/index.html`, `web/main/main.jpeg`
> 🎯 **2-2** SSE-KMS = `alias/wskorea26-s3-key`, PublicAccessBlock 4개 True, IsPublic False
> ⏳ 버킷 정책(OAC 허용)은 **10번 CloudFront** 생성 후 추가한다.

---

## 4️⃣ ECR — 컨테이너 이미지

> 📍 **ECR → Repositories → Create repository (Private)**
- Name `wskorea26-book-repo` · **Scan on push ✅** · **Encryption: KMS** (`alias/wskorea26-s3-key`) → Create.

### 4-1. 이미지 빌드 & push (docker 필요 — CloudShell 엔 docker 없음)
> ⚠️ docker 있는 로컬/EC2 에서 진행. **취약점 0** 을 위해 scratch 기반 이미지로.
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 -t $REG/wskorea26-book-repo:stable .   # book 을 scratch 로 감쌈
docker push $REG/wskorea26-book-repo:stable
```
> 🎯 **3-1**: scanOnPush=True · encryptionType=KMS · 태그 `stable` · Critical/High 취약점 없음.

---

## 5️⃣ DynamoDB

> 📍 **DynamoDB → Tables → Create table**

- Table name **`wskorea26-data-table`** · Partition key **`client_id` (String)** · 정렬키 없음.
- Table settings → **Customize** → Encryption → **Stored in your account** → `alias/wskorea26-dynamodb-key` → Create.
- 생성 후 → 테이블 → **Additional settings → Deletion protection → Turn on ✅**.
- **Indexes → Create index** (Lambda 조회/정렬용 GSI):
  - Partition `concert_name` (String) · Sort `created_at` (String)
  - Index name **`concert_name-created_at-index`** · Projection **All**.

> 🎯 **4-1**: client_id **HASH** · DeletionProtectionEnabled **True** · `alias/wskorea26-dynamodb-key`.

---

## 6️⃣ EKS 클러스터

### 6-1. 채점용 보안그룹 먼저
> 📍 **VPC → Security groups → Create security group**
- Name **`wskorea26-vpc-environment-sg`** · VPC = wskorea26-vpc
- Inbound: **HTTPS 443 · Source 0.0.0.0/0** · Outbound: All → Create. (유의사항 13)

### 6-2. 클러스터 생성
> 📍 **EKS → Add cluster → Create**

| 항목 | 값 |
|------|-----|
| Name | `wskorea26-cluster` |
| Kubernetes version | **1.35** |
| Cluster IAM role | `AmazonEKSClusterPolicy` 붙은 역할 |
| **Secrets encryption** | Enable → `alias/wskorea26-eks-key` |
| VPC | wskorea26-vpc |
| **Subnets** | **priv-subnet-c, priv-subnet-d 만** |
| Additional SG | `wskorea26-vpc-environment-sg` |
| Endpoint access | **Public and private** |
| Control plane logging | **5종 전부 ✅** (api·audit·authenticator·controllerManager·scheduler) |
| Access config | **EKS API and ConfigMap**, 생성자 admin 권한 ✅ |

- ⏱️ 약 10분 소요. 완료 후 **Access → Create access entry** 로 채점/본인 IAM 을
  `AmazonEKSClusterAdminPolicy` 로 등록(안 하면 CloudShell kubectl 거부됨).

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name wskorea26-cluster
kubectl get svc      # 접속 확인
```
> 🎯 **5-1**: name/version · 로그 5종 · `alias/wskorea26-eks-key` · priv-subnet-c/d.

---

## 7️⃣ 노드그룹 2개

> 📍 **EKS → wskorea26-cluster → Compute → Add node group** (2번)

| 항목 | addon | app |
|------|-------|-----|
| Name | `wskorea26-addon-ng` | `wskorea26-app-ng` |
| Node IAM role | Worker+CNI+ECR+SSM 정책 역할 | 동일 |
| Instance type | **t3.medium** | **t3.medium** |
| Scaling | desired 2 / min 2 / max 3 | 동일 |
| Subnets | priv-c, priv-d | priv-c, priv-d |
| **K8s labels** | `node-type = addon` | `node-type = app` |

- 노드 IAM 필수 정책: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`,
  `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore`.
- 인스턴스 **Name 태그**: addon=`wskorea26-addon-node`, app=`wskorea26-app-node`
  (콘솔 노드그룹이 태그를 못 주면 EC2 콘솔에서 인스턴스 Name 을 직접 지정).
- 시스템 파드를 addon 노드로 (채점 5-3):
  ```bash
  kubectl -n kube-system patch deploy coredns --type merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"node-type":"addon"}}}}}'
  ```
> 🎯 **5-2** nodegroupName·t3.medium·Name 태그·priv-c/d  ·  **5-3** ns wskorea26, app 파드=app 노드.

---

## 8️⃣ Lambda

> 📍 **Lambda → Create function → Author from scratch**

| 항목 | 값 |
|------|-----|
| Function name | `wskorea26-book-lambda` |
| Runtime | **Python 3.14** |
| 실행 역할 | 최소권한 새 역할(아래 정책) |
| Handler | `lambda_function.handler` |
| 환경변수 | `TABLE_NAME=wskorea26-data-table`, `GSI_NAME=concert_name-created_at-index` |

- 코드 로직: `concert_name` 쿼리 → GSI Query(`ScanIndexForward=False` 최신순) →
  없으면 400, 결과없으면 `[]`+200, **ALB 응답 포맷** 반환.
- 최소권한 정책(역할에 인라인):
  ```json
  { "Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":["dynamodb:Query"],
     "Resource":["arn:aws:dynamodb:ap-northeast-2:<ACCOUNT>:table/wskorea26-data-table",
                  "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT>:table/wskorea26-data-table/index/*"]},
    {"Effect":"Allow","Action":["kms:Decrypt","kms:DescribeKey"],
     "Resource":"<wskorea26-dynamodb-key ARN>"} ]}
  ```
> 🎯 **6-1**: python3.14 · `TABLE_NAME=wskorea26-data-table`. (연결값 하드코딩 금지 → 환경변수)

---

## 9️⃣ ALB — book

### 9-1. 보안그룹
> 📍 **EC2 → Security Groups → Create**
- `wskorea26-book-alb-sg` · Inbound **HTTP 80 · 0.0.0.0/0**(유의사항 6) · Outbound All.

### 9-2. 대상 그룹 2개
> 📍 **EC2 → Target groups → Create target group**

| Name | Type | 설정 |
|------|------|------|
| `wskorea26-book-tg` | **IP addresses** | HTTP **8080**, VPC=wskorea26-vpc, Health path `/health` |
| `wskorea26-lambda-tg` | **Lambda function** | `wskorea26-book-lambda` 지정 |

> book TG 대상 등록은 **11번**에서 파드 IP 자동(TargetGroupBinding).

### 9-3. ALB 생성
> 📍 **EC2 → Load Balancers → Create → Application Load Balancer**

| 항목 | 값 |
|------|-----|
| Name | `wskorea26-book-alb` |
| Scheme | **Internet-facing** |
| Subnets | pub-c, pub-d |
| Security group | `wskorea26-book-alb-sg` |
| Listener | **HTTP:80** → 기본동작 **Return fixed response 403** |

### 9-4. 리스너 규칙 (Listener HTTP:80 → Manage rules → Add rule)

| 우선순위 | 조건 (모두 AND) | 동작 |
|----------|-----------------|------|
| **10** | Path `/v1/book`·`/book` + Method `POST` + Header `X-Origin-Verify=wskorea26-cf` | forward → `wskorea26-book-tg` |
| **20** | Path `/book*` + Method `GET` + Header `X-Origin-Verify=wskorea26-cf` | forward → `wskorea26-lambda-tg` |
| 기본 | 그 외 | **403** |

> 💡 book 앱은 `/v1/book` 만 처리 → CloudFront 가 `/book`(POST)을 `/v1/book` 으로 재작성(10-4).
> 🎯 **7-1** internet-facing·80·HTTP  ·  **7-2** 규칙 헤더값 `wskorea26-cf`, 헤더없는 직접요청 403.

---

## 🔟 CloudFront

### 10-1. OAC
> 📍 **CloudFront → Origin access → Create control setting**
- Name `wskorea26-s3-oac` · Origin type **S3** · Sign requests.

### 10-2. 배포 생성
> 📍 **CloudFront → Create distribution**

| 항목 | 값 |
|------|-----|
| **Description(Comment)** | **`wskorea26-concert-cf`** (채점이 Comment 로 탐색!) |
| Default root object | `index.html` |
| Price class | **All** (전세계 빠른 접근) |

**Origin 2개:**

| Origin ID | Domain | 핵심 설정 |
|-----------|--------|-----------|
| `wskorea26-s3-origin` | S3 버킷 도메인 | **Origin path `/web/main`** · OAC=`wskorea26-s3-oac` · Custom header **`wskorea26-s3-access: true`** |
| `wskorea26-alb-origin` | ALB DNS 이름 | Protocol **HTTP only(80)** · Custom header **`X-Origin-Verify: wskorea26-cf`** |

**Behavior 2개:**

| Path pattern | Origin | 설정 |
|--------------|--------|------|
| Default `*` | `wskorea26-s3-origin` | Viewer **Redirect HTTP to HTTPS** · Cache **CachingOptimized** |
| `/book*` | `wskorea26-alb-origin` | 모든 HTTP 메서드 · Cache **CachingDisabled** · Origin request **AllViewer** |

### 10-3. S3 버킷 정책 (배포 생성 후 OAC 읽기 허용)
> 📍 **S3 → 버킷 → Permissions → Bucket policy → Edit**
```json
{ "Version":"2012-10-17","Statement":[{
  "Sid":"AllowCloudFrontOAC","Effect":"Allow",
  "Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"s3:GetObject",
  "Resource":"arn:aws:s3:::wskorea26-concert-bucket-<비번호>/*",
  "Condition":{"StringEquals":{"AWS:SourceArn":"<CloudFront Distribution ARN>"}}}]}
```

### 10-4. CloudFront Function (경로 재작성)
> 📍 **CloudFront → Functions → Create function** `wskorea26-book-rewrite`
```javascript
function handler(event) {
  var req = event.request;
  if (req.method === 'POST' && req.uri === '/book') { req.uri = '/v1/book'; }
  return req;
}
```
→ **Publish** → `/book*` behavior 의 **Viewer request** 에 연결.

> 🎯 **8-2** 기본=s3-origin, `/book*`=alb-origin, redirect-to-https
> 🎯 **8-3** 헤더 `X-Origin-Verify wskorea26-cf` / `wskorea26-s3-access true`
> 🎯 **8-4** `https://도메인` 200 · `http://도메인/` 301 · `/main.jpeg` 200·**180926 bytes**

---

## 1️⃣1️⃣ 애플리케이션 배포 (CloudShell)

```bash
kubectl create namespace wskorea26
```
book Pod 의 DynamoDB 접근 = **Pod Identity 또는 IRSA** 로 `wskorea26-book-sa` 에
최소권한(PutItem/Query + wskorea26-dynamodb-key) 부여. 매니페스트(`app.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: wskorea26-book, namespace: wskorea26 }
spec:
  replicas: 2
  selector: { matchLabels: { app: wskorea26-book } }
  template:
    metadata: { labels: { app: wskorea26-book } }
    spec:
      serviceAccountName: wskorea26-book-sa
      nodeSelector: { node-type: app }          # app 노드 전용
      containers:
      - name: book
        image: <ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/wskorea26-book-repo:stable
        ports: [{ containerPort: 8080 }]
        envFrom: [{ configMapRef: { name: wskorea26-book-config } }]   # AWS_REGION, TABLE_NAME
        readinessProbe: { httpGet: { path: /health, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: wskorea26-book-svc, namespace: wskorea26 }
spec:
  type: ClusterIP
  selector: { app: wskorea26-book }
  ports: [{ port: 80, targetPort: 8080 }]
```
파드 IP 를 `wskorea26-book-tg` 에 등록 = **AWS LB Controller + TargetGroupBinding**:
```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=wskorea26-cluster --set serviceAccount.create=true \
  --set nodeSelector.node-type=addon
kubectl apply -f - <<'EOF'
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: wskorea26-book-tgb, namespace: wskorea26 }
spec:
  serviceRef: { name: wskorea26-book-svc, port: 80 }
  targetType: ip
  targetGroupARN: <wskorea26-book-tg ARN>
EOF
```

---

## 1️⃣2️⃣ 모니터링 (CloudShell)

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

# Prometheus (addon 노드)
helm install prometheus prometheus-community/prometheus -n monitoring \
  --set server.nodeSelector.node-type=addon \
  --set kube-state-metrics.nodeSelector.node-type=addon \
  --set alertmanager.enabled=false --set pushgateway.enabled=false

# Grafana (addon 노드, 인터넷 LB=wskorea26-grafana-alb, admin/wsk2026!)
helm install grafana grafana/grafana -n monitoring \
  --set nodeSelector.node-type=addon \
  --set adminUser=admin --set adminPassword='wsk2026!' \
  --set service.type=LoadBalancer --set service.port=80 \
  --set 'service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-name=wskorea26-grafana-alb' \
  --set 'service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing'
```
- 데이터소스: `http://prometheus-server.monitoring.svc.cluster.local`
- 대시보드 **uid `wskorea26` · title `wskorea26-monitoring`**, 아래 **5개 패널**:

| 패널 | PromQL |
|------|--------|
| 컨테이너 CPU | `sum by(pod)(rate(container_cpu_usage_seconds_total{container!=""}[5m]))` |
| 컨테이너 메모리 | `sum by(pod)(container_memory_usage_bytes{container!=""})` |
| 실행중 Pod 수 | `sum(kube_pod_status_phase{phase="Running"})` |
| 재시작 횟수 | `sum by(pod)(kube_pod_container_status_restarts_total)` |
| 네트워크 수신 | `sum by(pod)(rate(container_network_receive_bytes_total[5m]))` |

- 접속 주소:
  ```bash
  echo "http://$(kubectl get svc grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/d/wskorea26/wskorea26-monitoring"
  ```
> 🎯 **10-1**: admin/wsk2026! 로그인 후 위 5개 지표가 대시보드에 표시.

---

## ✅ 최종 검증

```bash
CF=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='wskorea26-concert-cf'].DomainName|[0]" --output text)

curl -o /dev/null -s -w "%{http_code}\n" https://$CF            # 200 (정적 웹)
curl -o /dev/null -s -w "%{http_code}\n" http://$CF/            # 301 (HTTPS 리다이렉트)
curl -s -o /dev/null -w "%{size_download}\n" https://$CF/main.jpeg   # 180926

curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"client_id":"C1","username":"a","email":"a@a.com","concert_name":"CON1"}' https://$CF/book
curl -s "https://$CF/book?concert_name=CON1"                    # [ {...} ]
curl -s -o /dev/null -w "%{http_code}\n" "https://$CF/book"     # 400 (파라미터 없음)

ALB=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb --query "LoadBalancers[0].DNSName" --output text)
curl -o /dev/null -s -w "%{http_code}\n" http://$ALB/book       # 403 (직접 접근 차단)
```

### 최종 체크리스트
- [ ] KMS 별칭 3개 정확 (`-s3-key`/`-dynamodb-key`/`-eks-key`)
- [ ] VPC/서브넷 CIDR·이름 · private RTB = NAT only
- [ ] S3 객체 `web/main/*` · KMS · Public 차단 4종
- [ ] ECR scanOnPush/KMS/`stable`/취약점0
- [ ] DynamoDB client_id · 삭제방지 · KMS · GSI
- [ ] EKS 1.35 · 로그5종 · eks-key · priv 서브넷 · ns wskorea26 · 노드 label/tag
- [ ] Lambda python3.14 · TABLE_NAME
- [ ] ALB internet-facing · 80 · 헤더403
- [ ] CloudFront Comment · origin 2 · 헤더 2 · behavior 2 · 함수
- [ ] Grafana 대시보드 5개 지표
