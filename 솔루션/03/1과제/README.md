# 🏆 WSC2026 제1과제 — AWS 콘솔 풀이 (처음부터 끝까지)

> 인천기능경기대회 v2 문제지 + 채점기준표 기준 **콘솔 클릭 순서** 가이드.
> 리전은 전부 **서울(ap-northeast-2)**, CloudFront/WAF 만 **글로벌(us-east-1)**.
> 문서 안의 `<비번호>`, `<계정>`, `<vpc-id>` 등은 본인 값으로 바꿔 입력.

---

## 📋 진행 순서 한눈에

```
1. VPC 네트워크        → 2. KMS 키 5개        → 3. IAM 역할(pod/lambda)
   ↓
4. DynamoDB            → 5. ECR + 이미지푸시   → 6. EKS 클러스터+노드
   ↓
7. LB Controller 설치  → 8. Deployment(kubectl)→ 9. S3
   ↓
10. Lambda             → 11. CloudFront + WAF  → 12. Observability
   ↓
13. 마무리 점검(엔드포인트 Private 전환 · E2E 테스트)
```

## 🎯 배점 체크리스트

| # | 항목 | 배점 | 완료 |
|:-:|---|:-:|:-:|
| 1 | Networking | 2.0 | ☐ |
| 2 | Database | 1.3 | ☐ |
| 3 | Container Registry | 1.2 | ☐ |
| 4 | Container Orchestration | 3.0 | ☐ |
| 5 | Deployment | 6.5 | ☐ |
| 6 | S3 | 1.0 | ☐ |
| 7 | Lambda | 3.0 | ☐ |
| 8 | Load Balancer | 1.3 | ☐ |
| 9 | CloudFront | 4.0 | ☐ |
| 10 | WAF | 1.5 | ☐ |
| 11 | Observability | 5.2 | ☐ |
| | **합계** | **30** | |

## 🧰 준비물

- AWS 콘솔 로그인 (관리자급 권한)
- 로컬 or Cloud9/EC2 에 `awscli`, `kubectl`, `helm`, `docker`
- 배포파일: `book`(바이너리), `index.html`, `main.jpeg`, `Dockerfile`, `lambda_function.py`
  → 전부 [`../../03/1과제/files/`](../../03/1과제/files) 에 있음
- k8s 매니페스트/helm values → [`manifests/`](manifests) 폴더

> 💡 EKS 내부 리소스(Deployment·Service·Ingress·모니터링)는 콘솔만으로 못 만든다.
> `kubectl`/`helm` 으로 적용하며, 그 파일은 전부 `manifests/` 에 준비돼 있다.

---

# 1️⃣ Networking (VPC) — 2.0점

> **콘솔 경로:** `VPC` 서비스로 이동

### 1-1. VPC 생성
`VPC → Your VPCs → Create VPC`

| 항목 | 값 |
|---|---|
| 리소스 유형 | **VPC only** |
| 이름 | `wsc2026-skills-vpc` |
| IPv4 CIDR | `192.168.0.0/16` |

생성 후 → VPC 선택 → `Actions → Edit VPC settings` → **Enable DNS hostnames** ✔, **Enable DNS resolution** ✔

### 1-2. 서브넷 4개
`VPC → Subnets → Create subnet` (VPC = wsc2026-skills-vpc)

| 이름 | 가용영역 | CIDR | 구분 |
|---|:-:|---|:-:|
| `wsc2026-skills-hub-sub-a` | **2a** | `192.168.1.0/24` | Public |
| `wsc2026-skills-hub-sub-b` | **2b** | `192.168.10.0/24` | Public |
| `wsc2026-skills-app-sub-a` | **2a** | `192.168.2.0/24` | Private |
| `wsc2026-skills-app-sub-b` | **2b** | `192.168.20.0/24` | Private |

> hub 2개만: 선택 → `Actions → Edit subnet settings` → **Enable auto-assign public IPv4 address** ✔

### 1-3. Internet Gateway
`VPC → Internet gateways → Create` → 이름 `wsc2026-skills-igw` → 생성 →
`Actions → Attach to VPC` → `wsc2026-skills-vpc`

### 1-4. NAT Gateway 2개
`VPC → NAT gateways → Create`

| 이름 | 배치 서브넷 | Elastic IP |
|---|---|---|
| `wsc2026-skills-nat-a` | `wsc2026-skills-hub-sub-a` | **Allocate Elastic IP** 클릭 |
| `wsc2026-skills-nat-b` | `wsc2026-skills-hub-sub-b` | **Allocate Elastic IP** 클릭 |

### 1-5. Route Table 3개
`VPC → Route tables → Create` (VPC 선택)

| 이름 | 라우트 (`Edit routes`) | 연결 서브넷 (`Edit subnet associations`) |
|---|---|---|
| `wsc2026-skills-hub-rtb` | `0.0.0.0/0` → **igw** | hub-sub-a, hub-sub-b |
| `wsc2026-skills-app-rtb-a` | `0.0.0.0/0` → **nat-a** | app-sub-a |
| `wsc2026-skills-app-rtb-b` | `0.0.0.0/0` → **nat-b** | app-sub-b |

> ✅ **채점 1-1** VPC/서브넷 CIDR·이름 일치
> ✅ **채점 1-2** hub-rtb→igw, app-rtb-a→nat-a, app-rtb-b→nat-b

---

# 2️⃣ KMS 키 5개

> **콘솔 경로:** `KMS → Customer managed keys → Create key`
> 5개 모두 **대칭키 / 암호화·복호화** 로 만들고 아래 별칭을 지정.

| 별칭 (alias) | 용도 |
|---|---|
| `wsc2026-db-kms` | DynamoDB |
| `wsc2026-ecr-kms` | ECR |
| `wsc2026-eks-kms` | EKS Secret + 로그 |
| `wsc2026-bucket-kms` | S3 |
| `wsc2026-function-kms` | Lambda |

### 🚨 키 정책 주의 (채점 `check_kms`)
채점 스크립트는 키 정책에 **`"kms:*"` 또는 `:root` 가 있으면 즉시 FAIL** 처리한다.
Create key 마법사가 자동으로 넣는 "Enable IAM User Permissions"(root+kms:\*) 문을
**생성 후 반드시 삭제**하고, 관리 권한은 아래처럼 **구체적인 액션**만 남긴다.

<details><summary>📄 키 정책 템플릿 (펼치기) — <code>&lt;viaservice&gt;</code>만 키별로 교체</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Admin",
      "Effect": "Allow",
      "Principal": { "AWS": "<본인 배포 IAM ARN>" },
      "Action": [
        "kms:Create*","kms:Describe*","kms:Enable*","kms:List*","kms:Put*",
        "kms:Update*","kms:Revoke*","kms:Disable*","kms:Get*","kms:Delete*",
        "kms:TagResource","kms:UntagResource","kms:ScheduleKeyDeletion","kms:CancelKeyDeletion",
        "kms:Encrypt","kms:Decrypt","kms:ReEncrypt*","kms:GenerateDataKey*","kms:CreateGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ServiceUse",
      "Effect": "Allow",
      "Principal": { "AWS": "*" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncrypt*","kms:GenerateDataKey*","kms:DescribeKey","kms:CreateGrant"],
      "Resource": "*",
      "Condition": { "StringEquals": {
        "kms:CallerAccount": "<계정>",
        "kms:ViaService": "<viaservice>"
      }}
    }
  ]
}
```
`<viaservice>`: db→`dynamodb.ap-northeast-2.amazonaws.com` · ecr→`ecr.ap-northeast-2.amazonaws.com`
· bucket→`s3.ap-northeast-2.amazonaws.com` · function→`lambda.ap-northeast-2.amazonaws.com`

- **eks-kms**: ViaService 대신 EKS 클러스터 역할(6장) + `logs.ap-northeast-2.amazonaws.com` 허용
- **bucket-kms**: `cloudfront.amazonaws.com` 의 `kms:Decrypt` 허용 추가(11장)

> 정확한 최소권한 JSON 전체는 [`../../03/1과제/kms.tf`](../../03/1과제/kms.tf) 와 동일하게 맞추면 된다.
</details>

---

# 3️⃣ IAM 역할 (Pod · Lambda) 먼저 생성

> **콘솔 경로:** `IAM → Policies` (정책) → `IAM → Roles` (역할)
> ⚠️ **정책 Action 에 `*`(와일드카드)를 절대 넣지 말 것** — 채점 5-5/7-2 FAIL 원인.

### 3-1. Pod 역할 `wsc2026-book-pod-role`
① 정책 `wsc2026-book-pod-policy`:
```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["dynamodb:PutItem"],
   "Resource":"arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table"}]}
```
② 역할 `wsc2026-book-pod-role` → **Custom trust policy**:
```json
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"pods.eks.amazonaws.com"},
 "Action":["sts:AssumeRole","sts:TagSession"]}]}
```
→ ① 정책 연결.

### 3-2. Lambda 역할 `wsc2026-book-function-role`
① 정책 `wsc2026-book-function-policy`:
```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["dynamodb:Query"],
   "Resource":["arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table",
               "arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table/index/booking_id-index"]}]}
```
② 역할 → trust `lambda.amazonaws.com` → 위 정책 + AWS 관리형 **`AWSLambdaBasicExecutionRole`** 연결.

---

# 4️⃣ DynamoDB — 1.3점

> **콘솔 경로:** `DynamoDB → Tables → Create table`

| 항목 | 값 |
|---|---|
| Table name | `wsc2026-book-table` |
| Partition key | `client_id` (String) |
| Table settings | **Customize settings** |
| Capacity mode | **On-demand** |
| Encryption | **KMS – `wsc2026-db-kms`** |

**보조 인덱스(GSI)** — `Create global index`:
| Partition key | Index name | Projection |
|---|---|---|
| `booking_id` (String) | `booking_id-index` | **All** |

생성 후 테이블에서:
- `Additional settings → Point-in-time recovery` → **Turn on** (35일)
- `Additional settings → Deletion protection` → **Turn on**
- `Resource-based policy → Edit` → 아래 붙여넣기:

```json
{ "Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::<계정>:role/wsc2026-book-pod-role"},
   "Action":"dynamodb:PutItem","Resource":"arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table"},
  {"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::<계정>:role/wsc2026-book-function-role"},
   "Action":"dynamodb:Query","Resource":[
     "arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table",
     "arn:aws:dynamodb:ap-northeast-2:<계정>:table/wsc2026-book-table/index/booking_id-index"]}]}
```

> ✅ **채점 2-1** `client_id PAY_PER_REQUEST KMS True booking_id` · `ENABLED 35 ENABLED` ·
> PutItem→pod-role · Query→function-role · KMS PASS

---

# 5️⃣ ECR + 이미지 푸시 — 1.2점

> **콘솔 경로:** `ECR → Repositories → Create repository` (Private)

| 항목 | 값 |
|---|---|
| Repository name | `wsc2026-book-ecr` |
| Tag mutability | **Mutable with immutable exclusion** → Wildcard `v1*` |
| Scan on push | **Enable** |
| Encryption | **KMS – `wsc2026-ecr-kms`** |

이미지 빌드/푸시 (docker + 인터넷 필요):
```bash
cd ../../03/1과제/files          # Dockerfile, book 이 있는 폴더
ACCT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCT.dkr.ecr.ap-northeast-2.amazonaws.com

aws ecr get-login-password --region ap-northeast-2 \
  | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 --provenance=false \
  -t $REG/wsc2026-book-ecr:v1.0.0 .
docker push $REG/wsc2026-book-ecr:v1.0.0
```
> Dockerfile 이 `scratch` 기반 → OS 패키지 0 → **스캔 취약점 0**.
> ✅ **채점 3-1** `True MUTABLE_WITH_EXCLUSION v1* KMS` · `v1.0.0` · KMS PASS

---

# 6️⃣ EKS 클러스터 + 노드 — 3.0점

### 6-1. 클러스터 역할
`IAM → Roles → Create` → trust **`eks.amazonaws.com`** → `AmazonEKSClusterPolicy` →
이름 `wsc2026-eks-cluster-role`

### 6-2. Control Plane 로그 그룹
`CloudWatch → Log groups → Create` → `/aws/eks/wsc2026-eks-cluster/cluster` →
편집에서 **KMS `wsc2026-eks-kms`** 지정 · 보존 7일

### 6-3. 클러스터 생성
`EKS → Add cluster → Create`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-eks-cluster` |
| Version | **1.35** |
| Cluster role | `wsc2026-eks-cluster-role` |
| Secrets encryption | **Enable → `wsc2026-eks-kms`** |
| VPC | `wsc2026-skills-vpc` |
| Subnets | **app-sub-a, app-sub-b** (private) |
| Endpoint access | 생성 중엔 *Public and private*, **채점 전 Private 로 전환** |
| Control plane logging | api·audit·authenticator·controllerManager·scheduler **모두 ✔** |
| Cluster SG | 인바운드에 **0.0.0.0/0 금지** |

Add-ons: **CoreDNS · kube-proxy · Amazon VPC CNI · EKS Pod Identity Agent · Amazon EBS CSI Driver**

**CoreDNS 도메인 변경** (`Add-ons → CoreDNS → Edit → Configuration values`):
```json
{ "nodeSelector": { "wsc2026/node": "addon" },
  "corefile": ".:53 {\n errors\n health\n ready\n kubernetes wsc2026.skills.local in-addr.arpa ip6.arpa {\n pods insecure\n fallthrough in-addr.arpa ip6.arpa\n ttl 30\n }\n prometheus :9153\n forward . /etc/resolv.conf\n cache 30\n loop\n reload\n loadbalance\n}" }
```

### 6-4. 노드 역할
`IAM → Roles → Create` → trust **`ec2.amazonaws.com`** →
`AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryReadOnly` +
`AmazonEKS_CNI_Policy` + `AmazonSSMManagedInstanceCore` →
이름 `wsc2026-eks-node-role` (**Administrator 금지**)

### 6-5. 노드 그룹 2개
`EKS → 클러스터 → Compute → Add node group`

| 노드그룹 이름 | 타입 | 서브넷 | K8s 라벨 | 인스턴스 Name 태그 |
|---|:-:|---|---|---|
| `wsc2026-addon-nodegroup` | t3.medium ×2 | app-a,b | `wsc2026/node=addon` | `wsc2026-addon-node` |
| `wsc2026-workload-ng` | t3.medium ×2 | app-a,b | `wsc2026/node=application` | `wsc2026-workload-node` |

> 라벨은 마법사의 **Kubernetes labels** 에 입력. 인스턴스 Name 태그는 Launch template 로 지정하거나 생성 후 EC2 에서 수정.

### 6-6. 클러스터 접근 권한 (kubectl 용)
`EKS → Access → Create access entry` → 본인(및 채점자) IAM ARN →
정책 **`AmazonEKSClusterAdminPolicy`** (cluster scope)
```bash
aws eks update-kubeconfig --name wsc2026-eks-cluster --region ap-northeast-2
kubectl get nodes            # addon 2 + workload 2 = 4대 Ready 확인
```

> ✅ **채점 4-1** `1.35 ACTIVE False True True` · SG PASS · KMS PASS
> ✅ **채점 4-2** 노드그룹 이름/타입/라벨/2대 · **4-3** 세 역할 모두 Admin 아님

---

# 7️⃣ AWS Load Balancer Controller 설치

ALB 를 만드는 컨트롤러. Pod Identity 로 권한 부여 후 helm 설치.
```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)

# ① IAM 정책 (파일: ../../03/1과제/files/lb-controller-policy.json)
aws iam create-policy --policy-name wsc2026-AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://../../03/1과제/files/lb-controller-policy.json

# ② 역할 + Pod Identity
aws iam create-role --role-name wsc2026-lb-controller-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
aws iam attach-role-policy --role-name wsc2026-lb-controller-role \
  --policy-arn arn:aws:iam::$ACCT:policy/wsc2026-AWSLoadBalancerControllerIAMPolicy
aws eks create-pod-identity-association --cluster-name wsc2026-eks-cluster \
  --namespace kube-system --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::$ACCT:role/wsc2026-lb-controller-role

# ③ helm 설치
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=wsc2026-eks-cluster --set region=ap-northeast-2 --set vpcId=<vpc-id> \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set nodeSelector."wsc2026/node"=addon
```

---

# 8️⃣ Deployment (kubectl) — 6.5점

먼저 book SA 에 Pod Identity 연결:
```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
aws eks create-pod-identity-association --cluster-name wsc2026-eks-cluster \
  --namespace wsc2026 --service-account wsc2026-book-sa \
  --role-arn arn:aws:iam::$ACCT:role/wsc2026-book-pod-role
```
매니페스트 적용 (파일 안의 `<ACCOUNT>` 등 치환 후):
```bash
kubectl apply -f manifests/01-namespace.yaml
kubectl apply -f manifests/02-book.yaml     # configmap(book-config)/sa/deploy/svc/pdb
kubectl apply -f manifests/03-ingress.yaml  # ALB(wsc2026-app-alb)
```
핵심 값(매니페스트에 이미 반영):
- ConfigMap 이름 **`book-config`**, 데이터 `AWS_REGION`·`TABLE_NAME`
- replicas **2** · `nodeSelector: wsc2026/node=application`
- `topologySpreadConstraints: topology.kubernetes.io/zone`
- requests/limits **cpu 256m / mem 512Mi**
- startup/readiness/liveness **`/health:8080`**
- PDB **minAvailable 1**

```bash
kubectl get deploy,svc,ingress,pdb -n wsc2026   # 상태 확인
```

> ✅ **채점 5-1~5-5** Deploy 2/2 · Service · Ingress(ALB DNS 에 `wsc2026-app-alb`) · PDB ·
> zone 분산 · probe/configmap · application 노드 배치 · Pod Identity(`wsc2026-book-sa`)

---

# 9️⃣ S3 정적 호스팅 — 1.0점

> **콘솔 경로:** `S3 → Create bucket`

| 항목 | 값 |
|---|---|
| 이름 | `wsc2026-static-<임의영문4>-<비번호>-bucket` |
| 리전 | 서울 |
| Block all public access | **켜짐(전부 ✔)** |
| Default encryption | **SSE-KMS – `wsc2026-bucket-kms`** |
| Bucket Key | **Enable** |

업로드 (`Upload` 시 암호화 KMS `wsc2026-bucket-kms`):
- `static/index.html`
- `static/main.jpeg`

> 버킷 정책(CloudFront OAC 전용)은 **11장에서 CloudFront 생성 후** 추가.
> ✅ **채점 6-1** PublicAccessBlock 4×True · `aws:kms True` · 객체 KMS PASS

---

# 🔟 Lambda (GET API) — 3.0점

> **콘솔 경로:** `Lambda → Create function → Author from scratch`

| 항목 | 값 |
|---|---|
| 함수 이름 | `wsc2026-book-get-function` |
| Runtime | **Python 3.12** |
| 실행 역할 | 기존 `wsc2026-book-function-role` 사용 |

- **코드**: [`../../03/1과제/files/lambda_function.py`](../../03/1과제/files/lambda_function.py) 붙여넣고 **Deploy**
- `Configuration → Environment variables`:
  - `TABLE_NAME = wsc2026-book-table`, `INDEX_NAME = booking_id-index`
  - **Encryption → Customer managed key = `wsc2026-function-kms`** (전송/저장 중 암호화)
- `Configuration → Function URL → Create` → **Auth type = NONE**

> ✅ **채점 7-1** Runtime python3.12 · TABLE_NAME 이 KMS 암호문 출력
> ✅ **채점 7-2** role/policy 이름 일치 · Query 권한 · `*` 없음

---

# 1️⃣1️⃣ CloudFront + WAF — 4.0 + 1.5점

### 11-1. WAF (Global/CloudFront = us-east-1)
`WAF → Web ACLs → Create web ACL` (Region: **Global (CloudFront)**)

| 항목 | 값 |
|---|---|
| 이름 | `wsc2026-waf` |
| Rules | `AWSManagedRulesSQLiRuleSet`(Block) · `AWSManagedRulesCommonRuleSet`(XSS, Block) |
| Rate rule | limit **200**, window **1분(60초)**, by **IP**, Block |
| Default action | Allow |

### 11-2. CloudFront 배포
`CloudFront → Distributions → Create distribution`

**Origins 3개:**
| Origin | 원본 | 설정 |
|---|---|---|
| S3 | 정적 버킷 | **Origin access = OAC**(새로 `wsc2026-s3-oac`) · Origin path `/static` |
| ALB | `wsc2026-app-alb` DNS | Protocol **HTTP only** |
| Lambda | Function URL 호스트 | Protocol **HTTPS only** |

**Behaviors 3개:**
| Path pattern | Origin | Cache policy | 기타 |
|---|---|---|---|
| `Default (*)` | S3 | **CachingOptimized** | redirect-to-https |
| `/booking` | ALB | **CachingDisabled** | 모든 메서드 · **Function(viewer)로 `/booking`→`/v1/book` rewrite** |
| `/v1/book` | Lambda | **CachingDisabled** | 모든 메서드 |

기타: Default root object `index.html` · **WAF = `wsc2026-waf`** 연결 · 태그 `Name=wsc2026-cdn`

**CloudFront Function** (`Functions → Create` → viewer request 연결):
```js
function handler(event){ var r=event.request; if(r.uri.indexOf('/booking')===0){r.uri='/v1/book';} return r; }
```

### 11-3. S3 버킷 정책 (OAC 전용)
CloudFront 생성 시 안내되는 정책을 **S3 → 버킷 → Permissions → Bucket policy** 에 적용:
```json
{ "Version":"2012-10-17","Statement":[{
  "Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"s3:GetObject","Resource":"arn:aws:s3:::<버킷>/*",
  "Condition":{"StringEquals":{"AWS:SourceArn":"<CloudFront Distribution ARN>"}}}]}
```

### 11-4. ALB 를 CloudFront 전용으로
`EC2 → Security Groups → wsc2026-app-alb-sg` 인바운드 80 =
**CloudFront 관리형 prefix list** (`com.amazonaws.global.cloudfront.origin-facing`) 만.
(Any IP 금지 → 직접 curl 시 timeout = BLOCKED)

### 11-5. bucket-kms 에 CloudFront 허용
`wsc2026-bucket-kms` 정책에 추가:
```json
{ "Sid":"CF","Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"kms:Decrypt","Resource":"*",
  "Condition":{"StringEquals":{"aws:SourceAccount":"<계정>"}} }
```

> ✅ **채점 9-1** CF 200 · **9-2** S3 Optimized/ALB·Lambda Disabled · **9-3** POST/GET E2E
> ✅ **채점 10-1** SQLi 403 · XSS 403 · Rate 403

---

# 1️⃣2️⃣ Observability — 5.2점

### 12-1. Fluent Bit → CloudWatch
```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
# 로그그룹 (KMS eks-kms, 보존 7일)
aws logs create-log-group --log-group-name /wsc2026/app/log \
  --kms-key-id arn:aws:kms:ap-northeast-2:$ACCT:alias/wsc2026-eks-kms
aws logs put-retention-policy --log-group-name /wsc2026/app/log --retention-in-days 7

# 역할 + Pod Identity (sa=fluent-bit) : CloudWatch Logs 쓰기 + KMS
#   (역할 wsc2026-fluentbit-role 은 콘솔/CLI로 생성 후)
aws eks create-pod-identity-association --cluster-name wsc2026-eks-cluster \
  --namespace observability --service-account fluent-bit \
  --role-arn arn:aws:iam::$ACCT:role/wsc2026-fluentbit-role

helm install fluent-bit eks/aws-for-fluent-bit -n observability \
  -f manifests/fluentbit-values.yaml
```
`fluentbit-values.yaml` : `/health` 제외 + JSON 파싱(method/path/status/duration).

### 12-2. Prometheus + Alertmanager + Grafana
```bash
# Grafana CloudWatch 조회용 역할 wsc2026-grafana-role + Pod Identity (sa=grafana-sa)
aws eks create-pod-identity-association --cluster-name wsc2026-eks-cluster \
  --namespace observability --service-account grafana-sa \
  --role-arn arn:aws:iam::$ACCT:role/wsc2026-grafana-role

# 대시보드 ConfigMap (라벨 grafana_dashboard=1)
kubectl -n observability create configmap wsc2026-grafana-dashboard \
  --from-file=wsc2026-grafana-dashboard.json=../../03/1과제/k8s/wsc-eks-dashboard.json
kubectl -n observability label configmap wsc2026-grafana-dashboard grafana_dashboard=1

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f manifests/kps-values.yaml
```
`kps-values.yaml` 핵심: retention **7d** · 컴포넌트 `wsc2026/node=addon` · node-exporter DaemonSet ·
Grafana **admin / `Skills$#$@!`** · Service **LoadBalancer(internet)** ·
datasource **prometheus/alertmanager/cloudwatch**(소문자) · Alert **5종**.

Grafana 접속:
```bash
kubectl get svc -n observability | grep grafana   # EXTERNAL-IP 로 접속
# 로그인 admin / Skills$#$@!
```

> ✅ **채점 11-1** 파드 Running · **11-2** datasource 3종 + dashboard · **11-3** 패널/색상 · **11-4** Alert firing

---

# 1️⃣3️⃣ 마무리 점검 ✅

1. **EKS endpoint → Public = Disabled** 전환 (`EKS → 클러스터 → Networking → Manage endpoint access`) — 채점 4-1
2. 실행 중인 부하/테스트 파드 정리 (유의사항 7)
3. E2E 테스트:
```bash
CF=<cloudfront 도메인>
# POST -> booking_id
curl -s -X POST https://$CF/booking -H 'Content-Type: application/json' \
  -d '{"client_id":"C001","username":"Alice","email":"kim@example.com","concert_name":"Seoul2025"}'
# GET -> client_id,username,email,concert_name,created_at 순서 + 'YYYY-MM-DD HH:MM:SS KST'
curl -s "https://$CF/v1/book?booking_id=<위에서 받은 값>"
```
4. (제공 시) `mark.sh` 로 자가 채점.

---

## 📎 참고

| 원하는 것 | 위치 |
|---|---|
| 정확한 정책/설정 값 대조 | [`../../03/1과제/*.tf`](../../03/1과제) (테라폼 = 정답 소스) |
| k8s 매니페스트 | [`manifests/`](manifests) |
| 배포파일(book/lambda/Dockerfile 등) | [`../../03/1과제/files/`](../../03/1과제/files) |
| 값 변경 매핑표(30% 수정 대비) | [`../../03/1과제/README.md`](../../03/1과제/README.md) 2장 |
