# 🖥️ 2026 클라우드컴퓨팅 1과제 — AWS 콘솔 수동 구축 (처음부터 끝까지)

> 기준: **과제지_v3 / 채점기준표_v2** · 리전: **서울(ap-northeast-2)** 고정 · `<비번호>` 는 본인 번호로 치환
> 콘솔로만 안 되는 부분(EKS 노드그룹·앱·Prometheus)은 **CloudShell** 로 진행 (과제지도 노드그룹은 eksctl 요구).

---

## 📑 목차 & 진행 체크리스트

작업하면서 `[ ]` 를 `[x]` 로 바꿔가며 진행하세요.

- [ ] **0.** 사전 준비 (리전·CloudShell·배포파일)
- [ ] **1.** KMS 공용 키 `wsc-2026-key`
- [ ] **2.** VPC / 서브넷 / IGW / NAT / 라우팅
- [ ] **3.** VPC Flow Logs (KMS, 12필드)
- [ ] **4.** S3 + CloudFront (정적 호스팅)
- [ ] **5.** ECR + book 이미지 push
- [ ] **6.** DynamoDB + AWS Backup
- [ ] **7.** EKS 클러스터 (1.35)
- [ ] **8.** 노드그룹 app / addon
- [ ] **9.** 앱 배포 (book-0 / book-1)
- [ ] **10.** ALB (Load Balancer Controller)
- [ ] **11.** Prometheus (알림 3종)
- [ ] **12.** 마무리 (private 전환 · EKS admin)

### 🎯 채점 배점 한눈에 (총 30점)

| # | 항목 | 배점 | 이 문서 단계 |
|---|------|:---:|:---:|
| 1 | Network Configuration | 3.0 | 2, 3 |
| 2 | Static Page / CDN | 4.0 | 4 |
| 3 | Container Registry | 3.0 | 5 |
| 4 | NoSQL | 4.0 | 6 |
| 5 | Container Orchestration | 7.0 | 7, 8, 9 |
| 6 | Load Balancer | 4.0 | 10 |
| 7 | Prometheus | 5.0 | 11 |

---

## 0. 사전 준비

| 할 일 | 방법 |
|-------|------|
| 리전 확인 | 콘솔 우측 상단 = **아시아 태평양(서울) ap-northeast-2** |
| 신원 확인 | CloudShell 열고 `aws sts get-caller-identity` |
| 배포파일 준비 | `book`(바이너리), `index.html`, `main.jpeg`, `Dockerfile` 을 CloudShell 로 업로드 |

> 💡 **CloudShell** = 콘솔 상단 터미널 아이콘(`>_`). aws/kubectl/helm/docker 대부분 설치돼 있고 자격증명 자동. 이 가이드의 모든 CLI 는 CloudShell 기준.

---

## 1. 🔐 KMS 공용 키 (CMK)

FlowLogs · S3 · ECR · EKS 암호화에 **하나의 키를 공용**으로 쓴다 (채점 시 동일 key ARN 으로 보여야 함).

**콘솔 경로:** `KMS → 고객 관리형 키 → 키 생성`

| 항목 | 값 |
|------|-----|
| 키 유형 | 대칭 |
| 키 사용 | 암호화 및 복호화 |
| 별칭 | `wsc-2026-key` |
| 키 관리자 / 사용자 | 본인(관리자) 계정 |

**⚠️ 생성 후 키 정책(JSON)에 서비스 사용 허용 추가** — 아래를 `Statement` 배열에 넣는다:

<details><summary>📄 키 정책에 추가할 Statement (펼치기)</summary>

```json
{
  "Sid": "AllowCloudWatchLogs",
  "Effect": "Allow",
  "Principal": { "Service": "logs.ap-northeast-2.amazonaws.com" },
  "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncrypt*","kms:GenerateDataKey*","kms:DescribeKey"],
  "Resource": "*",
  "Condition": {
    "ArnLike": { "kms:EncryptionContext:aws:logs:arn": "arn:aws:logs:ap-northeast-2:<ACCOUNT_ID>:log-group:*" }
  }
}
```
S3/ECR/EKS 는 계정 root 가 이미 `kms:*` 를 가지면 `ViaService` 로 동작하지만, 명시하려면 `s3.` `ecr.` 서비스에 대한 `kms:GenerateDataKey*`·`Decrypt`·`CreateGrant` 를 추가한다.
</details>

> 📝 **생성된 키 ARN 을 메모장에 복사** → 2·3·4·5·7 단계에서 반복 사용.

**✅ 확인:** KMS 콘솔에서 별칭 `wsc-2026-key`, 상태 `사용 가능` 표시.

---

## 2. 🌐 VPC / 서브넷 / 라우팅

**콘솔 경로:** `VPC → VPC 생성 → "VPC만"` (리소스를 하나씩 통제하기 위해 개별 생성 권장)

### 2-1. VPC
| 항목 | 값 |
|------|-----|
| 이름 태그 | `wsc-vpc` |
| IPv4 CIDR | `10.0.0.0/16` |
| DNS 호스트 이름 | **활성화** (생성 후 작업 → VPC 설정 편집) |

### 2-2. 서브넷 4개 (`VPC → 서브넷 → 서브넷 생성`)
| 이름 | AZ | CIDR | 퍼블릭 IP 자동할당 |
|------|:--:|------|:---:|
| `wsc-pub-sn-a` | 2a | `10.0.0.0/24` | ✅ ON |
| `wsc-pub-sn-b` | 2b | `10.0.1.0/24` | ✅ ON |
| `wsc-priv-sn-a` | 2a | `10.0.2.0/24` | ❌ |
| `wsc-priv-sn-b` | 2b | `10.0.3.0/24` | ❌ |

> pub 서브넷은 생성 후 `작업 → 서브넷 설정 편집 → 퍼블릭 IPv4 주소 자동 할당` 체크.

### 2-3. 인터넷 게이트웨이 (`VPC → 인터넷 게이트웨이`)
- 이름 `wsc-igw` 생성 → `작업 → VPC에 연결` → `wsc-vpc`.

### 2-4. NAT 게이트웨이 2개 (`VPC → NAT 게이트웨이`) — 고가용성
| 이름 | 배치 서브넷 | 연결 유형 | EIP |
|------|-------------|-----------|-----|
| `wsc-nat-a` | `wsc-pub-sn-a` | 퍼블릭 | 새 EIP 할당 |
| `wsc-nat-b` | `wsc-pub-sn-b` | 퍼블릭 | 새 EIP 할당 |

> NAT 는 생성에 수 분 걸린다(상태 `Available` 대기).

### 2-5. 라우팅 테이블 3개 (`VPC → 라우팅 테이블`)
| 이름 | 경로 추가 | 연결 서브넷 |
|------|-----------|-------------|
| `wsc-pub-rt` | `0.0.0.0/0 → wsc-igw` | pub-sn-a, pub-sn-b |
| `wsc-priv-rt-a` | `0.0.0.0/0 → wsc-nat-a` | priv-sn-a |
| `wsc-priv-rt-b` | `0.0.0.0/0 → wsc-nat-b` | priv-sn-b |

> 각 RT: `라우팅 편집`으로 경로 추가 → `서브넷 연결 편집`으로 서브넷 연결.

### 2-6. EKS 서브넷 태그 (뒤 EKS/ALB 자동배치에 필요)
| 대상 서브넷 | 태그 Key | 태그 Value |
|-------------|----------|-----------|
| pub-sn-a, pub-sn-b | `kubernetes.io/role/elb` | `1` |
| priv-sn-a, priv-sn-b | `kubernetes.io/role/internal-elb` | `1` |
| 서브넷 4개 전부 | `kubernetes.io/cluster/wsc-eks-cluster` | `shared` |

**✅ 확인 (CloudShell):**
```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc-vpc" --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].[Tags[?Key==`Name`]|[0].Value,CidrBlock]' --output text
```
> 기대: 4개 서브넷 이름·CIDR 이 위 표와 일치.

---

## 3. 📊 VPC Flow Logs → CloudWatch (KMS · 12필드)

### 3-1. 로그 그룹 (`CloudWatch → 로그 그룹 → 로그 그룹 생성`)
| 항목 | 값 |
|------|-----|
| 이름 | `/aws/vpc/flowlogs` |
| KMS 키 ARN | `wsc-2026-key` ARN |
| 보존 기간 | 1주(7일) |

### 3-2. IAM 역할 (`IAM → 역할 → 역할 생성`)
- 신뢰 주체: **사용자 지정 신뢰 정책** → `vpc-flow-logs.amazonaws.com`
- 인라인 정책: `logs:CreateLogGroup`, `CreateLogStream`, `PutLogEvents`, `DescribeLogGroups`, `DescribeLogStreams`
- 역할 이름: `wsc-vpc-flowlogs-role`

### 3-3. Flow Log 생성 (`VPC → wsc-vpc 선택 → 흐름 로그 → 흐름 로그 생성`)
| 항목 | 값 |
|------|-----|
| 필터 | **모두(ALL)** |
| 최대 집계 간격 | 1분 |
| 대상 | **CloudWatch Logs 로 전송** |
| 대상 로그 그룹 | `/aws/vpc/flowlogs` |
| IAM 역할 | `wsc-vpc-flowlogs-role` |
| 로그 레코드 형식 | **사용자 지정 형식** ↓ |

**📋 사용자 지정 형식 (12필드, 순서 그대로 복붙):**
```
${account-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${start} ${end} ${action} ${vpc-id} ${subnet-id} ${region}
```

**✅ 확인:**
```bash
aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[*].{Format:LogFormat,DestType:LogDestinationType,Status:FlowLogStatus}' --output table
```
> 기대: DestType=`cloud-watch-logs`, Status=`ACTIVE`, Format 에 12필드 포함. 로그 그룹은 KMS 암호화.

---

## 4. 🪣 S3 + CloudFront (정적 호스팅)

### 4-1. S3 버킷 (`S3 → 버킷 만들기`)
| 항목 | 값 |
|------|-----|
| 이름 | `wsc-2026-bucket-<비번호>` |
| 리전 | 서울 |
| 퍼블릭 액세스 차단 | **4개 전부 ON** (외부 직접 접근 차단) |
| 기본 암호화 | **DSSE-KMS(이중 계층)** + 키 `wsc-2026-key` |
| 버킷 키 | **활성화** (비용 절감) |

→ 생성 후 `index.html`, `main.jpeg` **업로드**.

### 4-2. CloudFront Function (`CloudFront → 함수 → 함수 생성`)
| 항목 | 값 |
|------|-----|
| 이름 | `wsc-2026-functions` |
| 런타임 | **cloudfront-js-2.0** |

**📋 함수 코드 → 저장 후 반드시 `게시(Publish)`:**
```js
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === '/index' || uri === '/index/') request.uri = '/index.html';
  else if (uri === '/main' || uri === '/main/') request.uri = '/main.jpeg';
  return request;
}
```

### 4-3. 배포(Distribution) (`CloudFront → 배포 생성`)
| 항목 | 값 |
|------|-----|
| 원본 도메인 | 위 S3 버킷 선택 |
| 원본 액세스 | **OAC(Origin access control)** 새로 생성 → 사용 |
| 뷰어 프로토콜 | Redirect HTTP → HTTPS |
| 기본 캐시 동작 → 함수 연결 | **뷰어 요청 = `wsc-2026-functions`** |
| 이름/설명 | `wsc-2026-cloud-front` |

→ 생성 시 안내되는 **버킷 정책**(`cloudfront.amazonaws.com` + `AWS:SourceArn` 조건)을 **S3 버킷 정책에 붙여넣기**.

**✅ 확인:**
```bash
DOMAIN=<배포 도메인>.cloudfront.net
curl -I https://$DOMAIN/index   # → HTTP/2 200, content-type: text/html
curl -I https://$DOMAIN/main    # → HTTP/2 200, content-type: image/jpeg
```

---

## 5. 📦 ECR + book 이미지 push

### 5-1. 리포지토리 (`ECR → 리포지토리 생성 → 프라이빗`)
| 항목 | 값 |
|------|-----|
| 이름 | `book-ecr` |
| 태그 변경 가능성 | **IMMUTABLE(변경 불가)** |
| 푸시 시 스캔 | **ON** |
| 암호화 | **KMS** + `wsc-2026-key` |

### 5-2. 이미지 빌드 & 푸시 (CloudShell, 배포파일 있는 디렉터리에서)
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REG=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 -t $REG/book-ecr:latest .
docker push $REG/book-ecr:latest
```

**✅ 확인:**
```bash
aws ecr describe-repositories --repository-names book-ecr \
  --query 'repositories[0].{Mut:imageTagMutability,Enc:encryptionConfiguration.encryptionType}'
# → IMMUTABLE / KMS
aws ecr describe-image-scan-findings --repository-name book-ecr --image-id imageTag=latest \
  --query 'imageScanFindings.findingSeverityCounts'   # → CRITICAL/HIGH 없음(0)
```

---

## 6. 🗄️ DynamoDB + AWS Backup

### 6-1. 테이블 (`DynamoDB → 테이블 생성`)
| 항목 | 값 |
|------|-----|
| 이름 | `wsc-dynamo` |
| 파티션 키 | `booking_id` (문자열) |
| 용량 모드 | **온디맨드(PAY_PER_REQUEST)** |
| 암호화 | **AWS 관리형 키**(aws/dynamodb) |

→ 생성 후 **추가 설정**:
- `백업 → 특정 시점 복구(PITR)` **켜기**
- `추가 설정 → 삭제 방지` **켜기**

### 6-2. 백업 볼트 시드 (EFS 자동 백업)
백업 저장소로 **`aws/efs/automatic-backup-vault`** 를 써야 하는데, 이 볼트는 **EFS 자동 백업을 켜면 자동 생성**된다.
1. `EFS → 파일 시스템 생성` (기본값, 이름 아무거나)
2. 생성한 FS → `백업 → 자동 백업 켜기` → 잠시 후 Backup 콘솔에 `aws/efs/automatic-backup-vault` 생김.

### 6-3. 백업 계획 (`AWS Backup → 백업 계획 → 새로 만들기`)
| 항목 | 값 |
|------|-----|
| 계획 이름 | `wsc-dynamo-backup-plan` |
| 대상 볼트 | `aws/efs/automatic-backup-vault` |
| 스케줄 | 매일 |
| 콜드 스토리지 이동 | **30일** |
| 만료(삭제) | **120일** |

→ `리소스 할당`: 테이블 `wsc-dynamo`, **IAM 역할 = `AWSBackupDefaultServiceRole`**.

**✅ 확인:**
```bash
aws dynamodb describe-table --table-name wsc-dynamo \
  --query 'Table.{Bill:BillingModeSummary.BillingMode,SSE:SSEDescription.SSEType,Del:DeletionProtectionEnabled}'
# → PAY_PER_REQUEST / KMS / true
```

---

## 7. ☸️ EKS 클러스터 (1.35)

노드그룹까지 eksctl 로 하는 게 편하다. 먼저 클러스터만 만든다. `<...>` 를 실제 ID 로 치환.

<details><summary>📄 cluster.yaml (펼치기)</summary>

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: wsc-eks-cluster
  region: ap-northeast-2
  version: "1.35"
vpc:
  id: "<wsc-vpc-id>"
  subnets:
    private:
      priv-a: { id: "<priv-sn-a-id>" }
      priv-b: { id: "<priv-sn-b-id>" }
  clusterEndpoints:
    publicAccess: true      # 배포 중에만 열어둠 (12단계에서 false)
    privateAccess: true
secretsEncryption:
  keyARN: "<wsc-2026-key ARN>"
cloudWatch:
  clusterLogging:
    enableTypes: ["api","audit","authenticator","controllerManager","scheduler"]
EOF
```
</details>

```bash
eksctl create cluster -f cluster.yaml --without-nodegroup   # ~15분
```

**✅ 확인:**
```bash
aws eks describe-cluster --name wsc-eks-cluster \
  --query 'cluster.{V:version,S:status,Log:logging.clusterLogging[0].enabled}'
# → 1.35 / ACTIVE / true (로깅 5종), encryptionConfig 에 keyArn
```

---

## 8. 🖧 노드그룹 app / addon (managed, eksctl)

```bash
# App 노드그룹 — taint 로 book 파드만 이 노드에 스케줄
eksctl create nodegroup --cluster wsc-eks-cluster --region ap-northeast-2 \
  --name wsc-app-nodegroup --managed --node-type t3.medium \
  --nodes 2 --nodes-min 2 --nodes-max 3 --node-private-networking \
  --node-labels "node=app" --node-taints "node=app:NoSchedule"

# Addon 노드그룹 — 그 외 부가 서비스용
eksctl create nodegroup --cluster wsc-eks-cluster --region ap-northeast-2 \
  --name wsc-addon-nodegroup --managed --node-type t3.medium \
  --nodes 2 --nodes-min 2 --nodes-max 3 --node-private-networking \
  --node-labels "node=addon"
```

| 항목 | app | addon |
|------|-----|-------|
| 노드그룹 이름 | `wsc-app-nodegroup` | `wsc-addon-nodegroup` |
| 인스턴스 타입 | t3.medium | t3.medium |
| Label | `node=app` | `node=addon` |
| 인스턴스 Name 태그 | `wsc-app-node` | `wsc-addon-node` |

> Name 태그는 EC2 콘솔에서 각 노드에 직접 설정하거나, eksctl `--tags` 로 지정.

**✅ 확인:**
```bash
for NG in wsc-app-nodegroup wsc-addon-nodegroup; do
  aws eks describe-nodegroup --cluster-name wsc-eks-cluster --nodegroup-name $NG \
    --query 'nodegroup.{Type:instanceTypes,Labels:labels}'; done
# → t3.medium, node: app / node: addon
```

---

## 9. 🚀 앱 배포 (book-0 / book-1)

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name wsc-eks-cluster
kubectl create namespace book
```

> DynamoDB 접근 권한은 **Pod Identity**(또는 IRSA)로 `book` 네임스페이스 서비스어카운트에 부여.

<details><summary>📄 book.yaml — StatefulSet + Service (펼치기)</summary>

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: book, namespace: book, labels: { app: book } }
spec:
  serviceName: book
  replicas: 2                       # → 파드 이름 book-0, book-1
  selector: { matchLabels: { app: book } }
  template:
    metadata: { labels: { app: book } }
    spec:
      nodeSelector: { node: app }   # app 노드에만
      tolerations:
        - { key: node, operator: Equal, value: app, effect: NoSchedule }
      containers:
        - name: book
          image: <ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/book-ecr:latest
          ports: [ { containerPort: 8080 } ]
          env:
            - { name: AWS_REGION, value: ap-northeast-2 }
            - { name: TABLE_NAME, value: wsc-dynamo }
          readinessProbe: { httpGet: { path: /health, port: 8080 } }
          livenessProbe:  { httpGet: { path: /health, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: book, namespace: book }
spec:
  selector: { app: book }
  ports: [ { port: 8080, targetPort: 8080 } ]
```
</details>

```bash
kubectl apply -f book.yaml
```

**✅ 확인:**
```bash
kubectl get pods -n book -l app=book       # → book-0, book-1  Running
```

---

## 10. ⚖️ ALB (AWS Load Balancer Controller)

### 10-1. 컨트롤러 설치 (addon 노드 구동)
```bash
# 컨트롤러용 IAM 정책/역할(Pod Identity) 부여 후
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=wsc-eks-cluster --set region=ap-northeast-2 \
  --set vpcId=<wsc-vpc-id> --set nodeSelector.node=addon
```

### 10-2. ALB + 대상그룹 + 규칙
| 항목 | 값 |
|------|-----|
| ALB 이름 | `wsc-alb` |
| Scheme | **Internet-facing** |
| 서브넷 | `wsc-pub-sn-a`, `wsc-pub-sn-b` |
| 리스너 | **HTTP 80** |
| 대상 그룹 | **Target type = IP**, 포트 8080, 헬스체크 `/health` |
| 리스너 규칙 | `/health`, `/v1/*` → book 대상그룹 **forward** |
| 기본 동작 | **고정 응답 404** (정의 안된 경로) |

> 💡 **핵심:** 대상 그룹은 `Target type = IP`. book 은 EKS 파드라 IP 가 계속 바뀌므로,
> 파드 IP 를 대상그룹에 **자동 등록**해줘야 한다. 그 역할을 **LB Controller + `TargetGroupBinding`** 이 한다.
> 아래 **방법 A(권장)** 또는 **방법 B** 중 하나로 진행.

---

#### ✅ 방법 A (권장) — 콘솔에서 ALB 직접 만들고 `TargetGroupBinding` 으로 파드 IP 연결

404 기본응답·경로 규칙을 **콘솔에서 정확히 통제**할 수 있어 채점에 유리하다.

**① 대상 그룹 생성** — `EC2 → 대상 그룹 → 대상 그룹 생성`
| 항목 | 값 |
|------|-----|
| 대상 유형 | **IP 주소** |
| 이름 | `wsc-book-tg` |
| 프로토콜/포트 | HTTP / **8080** |
| VPC | `wsc-vpc` |
| 상태 검사 경로 | `/health` (정상 코드 200) |
> ⚠️ 대상은 **지금 등록하지 않는다**(비워 둠). 파드 IP 는 ③에서 컨트롤러가 자동 등록.

**② ALB 생성** — `EC2 → 로드 밸런서 → 로드 밸런서 생성 → Application Load Balancer`
| 항목 | 값 |
|------|-----|
| 이름 | `wsc-alb` |
| 체계(Scheme) | **인터넷 경계(Internet-facing)** |
| 서브넷 | `wsc-pub-sn-a`, `wsc-pub-sn-b` |
| 보안 그룹 | 인바운드 **80** 허용(0.0.0.0/0) |
| 리스너 | **HTTP:80** → 기본 작업 **고정 응답(fixed-response) 404** |

→ 생성 후 **리스너(HTTP:80) → 규칙 관리**에서 우선순위 규칙 추가:
| 우선순위 | 조건(경로) | 작업 |
|:---:|------|------|
| 10 | `/health` | `wsc-book-tg` 로 전달(forward) |
| 20 | `/v1/*` | `wsc-book-tg` 로 전달(forward) |
| 기본 | (그 외 전부) | **404 고정 응답** |

**③ 파드 IP 를 대상그룹에 자동 등록** — `TargetGroupBinding` (CloudShell)

먼저 대상그룹 ARN 을 구하고, book Service(ClusterIP, 포트 8080)를 대상그룹에 바인딩한다.
```bash
TG_ARN=$(aws elbv2 describe-target-groups --names wsc-book-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: book-tgb
  namespace: book
spec:
  serviceRef:
    name: book          # 9단계에서 만든 Service
    port: 8080
  targetType: ip
  targetGroupARN: $TG_ARN
EOF
```
> 이제 LB Controller 가 book 파드 IP(8080)를 `wsc-book-tg` 에 **자동 등록/갱신**한다.
> (9단계의 `Service/book` 이 파드를 selector 로 잡고 있어야 함 — `selector: app=book`.)

**③ 확인:**
```bash
kubectl get targetgroupbinding -n book                 # book-tgb 존재
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[*].{IP:Target.Id,State:TargetHealthState}'
# → 파드 IP 2개, State: healthy
```

---

#### 방법 B — Ingress 로 ALB 자동 생성 (대안)

`kubectl` 로 Ingress 만 만들면 LB Controller 가 ALB·대상그룹을 **자동 생성**한다.
경로/404 규칙을 annotation·rules 로 표현한다.

<details><summary>📄 book-ingress.yaml (펼치기)</summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: book
  namespace: book
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: wsc-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip          # ★ IP 타입
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/subnets: <pub-sn-a-id>,<pub-sn-b-id>
    # 정의 안된 경로 404 기본 응답
    alb.ingress.kubernetes.io/actions.resp404: >
      {"type":"fixed-response","fixedResponseConfig":{"statusCode":"404","contentType":"application/json","messageBody":"{\"message\":\"not found\"}"}}
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /health
            pathType: Prefix
            backend: { service: { name: book, port: { number: 8080 } } }
          - path: /v1
            pathType: Prefix
            backend: { service: { name: book, port: { number: 8080 } } }
          - path: /                          # 그 외 전부 → 404
            pathType: Prefix
            backend: { service: { name: resp404, port: { name: use-annotation } } }
EOF
```
</details>

```bash
kubectl apply -f book-ingress.yaml
# ALB 프로비저닝까지 1~2분. 이름 wsc-alb 로 생성됨.
```
> 방법 B 는 대상그룹 이름이 자동 생성되므로, 채점이 대상그룹 **이름**을 보지 않는다면 무방하다.
> 이름·404 세부제어가 필요하면 **방법 A** 를 쓴다.

---

**✅ 확인:**
```bash
ALB=$(aws elbv2 describe-load-balancers --names wsc-alb --query 'LoadBalancers[0].DNSName' --output text)
curl -I http://$ALB/health     # → 200
curl -X POST http://$ALB/v1/book -H "Content-Type: application/json" \
  -d '{"client_id":"C001","username":"Alice","email":"a@b.com","concert_name":"Seoul2025"}'
# → {"booking_id":"XXXX"}
curl -I http://$ALB/nope       # → 404
```

---

## 11. 📈 Prometheus (알림 3종)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
```

<details><summary>📄 values.yaml (펼치기)</summary>

```yaml
grafana: { enabled: false }
alertmanager: { enabled: false }
prometheusOperator: { nodeSelector: { node: addon } }
kube-state-metrics: { nodeSelector: { node: addon } }
prometheus:
  prometheusSpec:
    scrapeInterval: 15s
    evaluationInterval: 15s
    nodeSelector: { node: addon }
    ruleSelectorNilUsesHelmValues: false
additionalPrometheusRulesMap:
  book:
    groups:
      - name: book
        rules:
          - alert: BookPodNotRunning
            expr: kube_pod_status_phase{namespace="book",pod=~"book-.*",phase="Running"} == 0
            for: 30s
          - alert: BokPodCrashLooping        # ⚠️ 과제지 표기 그대로(오타 포함)
            expr: increase(kube_pod_container_status_restarts_total{namespace="book",pod=~"book-.*"}[5m]) > 2
            for: 30s
          - alert: BookPodNotReady
            expr: kube_pod_status_ready{namespace="book",condition="true",pod=~"book-.*"} == 0
            for: 30s
```
</details>

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n prometheus --create-namespace -f values.yaml
```

**✅ 확인:**
```bash
kubectl get prometheus -n prometheus -o yaml | grep -E "scrapeInterval|evaluationInterval"
# → 둘 다 15s
kubectl -n prometheus port-forward svc/prometheus-operated 9090:9090
#  브라우저: http://localhost:9090/alerts  → 3개 룰 표시
```
> 룰 이름 3종: `BookPodNotRunning`, `BokPodCrashLooping`, `BookPodNotReady`

---

## 12. 🏁 마무리

### 12-1. EKS private-only 전환 (채점 5-1 = PublicEndpoint:False)
```bash
aws eks update-cluster-config --region ap-northeast-2 --name wsc-eks-cluster \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
```

### 12-2. 채점 계정에 EKS 관리자 권한 부여
```bash
PRINCIPAL=$(aws sts get-caller-identity --query Arn --output text)
aws eks create-access-entry --cluster-name wsc-eks-cluster --principal-arn $PRINCIPAL
aws eks associate-access-policy --cluster-name wsc-eks-cluster --principal-arn $PRINCIPAL \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### 12-3. 정리
- [ ] 실행 중이던 **부하 테스트 / port-forward 종료**
- [ ] 모든 리소스 **Name 태그** 재확인 (채점 시 태그로 조회)

---

## 📌 참고

- **자동화 버전(테라폼)**: `../../01/1과제/` — 값 30% 변경 시 "어느 파일 어디를 고칠지"는 그쪽 `README.md` 의 **값 변경 시 수정 위치** 표 참고.
- 콘솔로 재현할 때도 각 단계의 **이름 / CIDR / 포트** 만 새 값으로 바꾸면 된다.
- ⚠️ 이 문서의 `<wsc-vpc-id>`, `<priv-sn-a-id>`, `<ACCOUNT>`, `<비번호>` 는 **모두 본인 값으로 치환** 후 실행.
