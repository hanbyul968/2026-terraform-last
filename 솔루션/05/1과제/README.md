# 🏆 제61회 인천기능경기대회 클라우드컴퓨팅 제1과제 — AWS 콘솔 풀이 (처음부터 끝까지)

> 문제지 v2 + 채점기준표 v4 기준 **콘솔 클릭 순서** 가이드.
> 리전은 전부 **서울(ap-northeast-2)**, **WAF(CloudFront 스코프)만 글로벌(us-east-1)**.
> 문서 안의 `<비번호>`, `<ACCOUNT_ID>`, `<OIDC_ID>`, `<DIST_ID>` 는 본인 값으로 바꿔 입력.

---

## 📋 진행 순서 한눈에

```
1. KMS 키 3개        → 2. VPC 네트워크        → 3. VPC 엔드포인트
   ↓
4. ECR + 캐시        → 5. DynamoDB            → 6. IAM 역할
   ↓
7. EKS 클러스터      → 8. S3                  → 9. ALB + 타겟그룹
   ↓
10. Lambda           → 11. WAF(글로벌)        → 12. CloudFront
   ↓
13. CloudShell: 이미지 빌드/푸시 · 노드그룹 · 앱 배포(kubectl/helm)
   ↓
14. Monitoring(Grafana · Fluent Bit) → 15. 최종 점검 + 채점 직전 정리
```

## 🎯 배점 체크리스트 (총 30점)

| # | 항목 | 배점 | 완료 |
|:-:|---|:-:|:-:|
| 1 | Network Configuration | 3.0 | ☐ |
| 2 | Container Registry | 2.5 | ☐ |
| 3 | Database | 2.5 | ☐ |
| 4 | Container | 6.5 | ☐ |
| 5 | Load Balancing | 1.0 | ☐ |
| 6 | Static Web Hosting | 2.0 | ☐ |
| 7 | Lambda | 1.0 | ☐ |
| 8 | CDN | 5.5 | ☐ |
| 9 | WAF | 3.0 | ☐ |
| 10 | Monitoring | 3.0 | ☐ |
| | **합계** | **30** | |

## 🧰 준비물

- AWS 콘솔 로그인(관리자급) + **CloudShell**(콘솔 우상단 `>_`)
- 배포파일: `book`(바이너리), `Dockerfile`, `index.html`, `main.jpeg`, `lambda_function.py`
- k8s 매니페스트/helm values → 이 폴더의 [`manifests/`](manifests) 에 준비됨

> 💡 EKS 내부 리소스(Deployment·Service·TargetGroupBinding·모니터링)는 콘솔로 못 만든다.
> 인프라는 **콘솔**, 컨테이너 이미지·kubectl·helm 은 **CloudShell** 로 진행한다.

---

# 1️⃣ KMS 키 3개

> **콘솔 경로:** `KMS → 고객 관리형 키 → 키 생성` (전부 **대칭 / 암호화·복호화**)

| 별칭(alias) | 용도 |
|---|---|
| `alias/gj2026-db-key` | DynamoDB 암호화 |
| `alias/gj2026-eks-key` | EKS Secrets 암호화 |
| `alias/gj2026-s3-key` | S3 암호화 |

### 🔑 S3 키만 정책에 CloudFront 허용 추가
`alias/gj2026-s3-key` 선택 → `키 정책 → 편집` → Statement 에 아래 추가:

<details><summary>📄 S3 KMS 키 정책 추가분 (펼치기)</summary>

```json
{
  "Sid": "AllowCloudFront",
  "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" },
  "Action": ["kms:Decrypt", "kms:GenerateDataKey*"],
  "Resource": "*",
  "Condition": { "ArnLike": { "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/*" } }
}
```
</details>

---

# 2️⃣ Network (VPC) — 3.0점

> **콘솔 경로:** `VPC` 서비스. ⚠️ NAT Gateway 는 **만들지 않는다**(전부 Private).

### 2-1. VPC 생성
`VPC → VPC 생성 → VPC만`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-vpc` |
| IPv4 CIDR | `10.0.0.0/16` |

생성 후 → `작업 → VPC 설정 편집` → **DNS 확인** ✔, **DNS 호스트 이름** ✔

### 2-2. 서브넷 2개
`VPC → 서브넷 → 서브넷 생성` (VPC = gj2026-vpc)

| 이름 | 가용영역 | CIDR |
|---|:-:|---|
| `gj2026-private-subnet-a` | **2a** | `10.0.10.0/24` |
| `gj2026-private-subnet-b` | **2b** | `10.0.11.0/24` |

두 서브넷 모두 → `작업 → 서브넷 설정 편집` → **리소스 이름 DNS A 레코드 자동 할당** ✔
두 서브넷 모두 **태그 추가**(EKS/ALB 자동 검색용):

| 태그 키 | 값 |
|---|---|
| `kubernetes.io/cluster/gj2026-eks-cluster` | `shared` |
| `kubernetes.io/role/internal-elb` | `1` |

### 2-3. Internet Gateway
`VPC → 인터넷 게이트웨이 → 생성` → 이름 `gj2026-igw` → `작업 → VPC에 연결` → `gj2026-vpc`
> CloudFront VPC Origin 연동 때문에 IGW는 **붙이되**, 라우팅에 `0.0.0.0/0` 은 넣지 않는다 → Private 유지.

### 2-4. 라우팅 테이블 2개
`VPC → 라우팅 테이블 → 생성` (VPC = gj2026-vpc)

| 이름 | 경로 | 연결 서브넷 |
|---|---|---|
| `gj2026-private-rtb-a` | 로컬(10.0.0.0/16)만 | gj2026-private-subnet-a |
| `gj2026-private-rtb-b` | 로컬(10.0.0.0/16)만 | gj2026-private-subnet-b |

> ✅ **채점 1-1** VPC/서브넷 CIDR·AZ 일치
> ✅ **채점 1-2** rtb-a·rtb-b 로컬 경로
> ✅ **채점 1-3** NAT Gateway **0개**, IGW 존재

---

# 3️⃣ VPC 엔드포인트

> Private 노드가 AWS API·ECR·S3·DynamoDB 에 접근하려면 **필수**.

### 3-1. Gateway 엔드포인트 2개
`VPC → 엔드포인트 → 엔드포인트 생성` (유형 Gateway, 라우팅테이블 a·b 선택)

- `com.amazonaws.ap-northeast-2.s3`
- `com.amazonaws.ap-northeast-2.dynamodb`

### 3-2. 엔드포인트용 보안그룹
`보안 그룹 생성` → 이름 `gj2026-vpce-sg` (VPC gj2026-vpc)

| 방향 | 규칙 |
|---|---|
| 인바운드 | `HTTPS 443` ← `10.0.0.0/16` |
| 아웃바운드 | 전체 허용 |

### 3-3. Interface 엔드포인트
`엔드포인트 생성` — 유형 **Interface**, 서브넷 a·b, 보안그룹 `gj2026-vpce-sg`, **프라이빗 DNS 활성화** ✔.
아래 서비스 각각(서비스명 = `com.amazonaws.ap-northeast-2.<값>`):

```
ecr.api   ecr.dkr   sts   logs   ec2   eks   eks-auth
elasticloadbalancing   autoscaling   ssm   ssmmessages   ec2messages   monitoring
```

---

# 4️⃣ ECR — 2.5점

### 4-1. book 리포지토리
`ECR → 리포지토리 생성` (프라이빗)

| 항목 | 값 |
|---|---|
| 이름 | `book` |
| 태그 변경 | 변경 가능(MUTABLE) |

### 4-2. Pull-through cache (public.ecr.aws 미러)
`ECR → 풀 스루 캐시 → 규칙 생성`

| 항목 | 값 |
|---|---|
| 업스트림 | **ECR Public** (`public.ecr.aws`) |
| 리포지토리 접두사 | `ecr-public` |

> Private 노드는 외부 이미지를 `<ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/ecr-public/...` 로 받는다.
> ✅ **채점 2-1** `book` 리포지토리 · ✅ **채점 2-2** book 이미지 크기 ≤ 3MB (13-A upx 압축)

---

# 5️⃣ DynamoDB — 2.5점

> **콘솔 경로:** `DynamoDB → 테이블 생성`

| 항목 | 값 |
|---|---|
| 테이블 이름 | `books` |
| 파티션 키 | `booking_id` (문자열) |
| 용량 | 온디맨드 |
| 암호화 | **고객 관리형 키** → `alias/gj2026-db-key` |

**GSI 추가**(테이블 생성 시 또는 인덱스 탭):
- 먼저 속성 `client_id`(문자열) 추가 → 보조 인덱스 생성
- 인덱스 이름 `client_id-index`, 파티션 키 `client_id`, 프로젝션 **ALL**

### 5-1. 리소스 기반 정책 (쓰기는 book 앱만) — 채점 3-3
테이블 → `권한 → 리소스 기반 정책 → 정책 편집`:

<details><summary>📄 DynamoDB 리소스 정책 (펼치기)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyWriteExceptBook",
    "Effect": "Deny",
    "Principal": "*",
    "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:BatchWriteItem"],
    "Resource": "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/books",
    "Condition": { "ArnNotLike": { "aws:PrincipalArn": "arn:aws:iam::<ACCOUNT_ID>:role/gj2026-book-app-role" } }
  }]
}
```
</details>

> ⚠️ `DeleteItem` 은 **일부러 제외** → 채점 전 테이블 비우기를 운영자가 할 수 있게.
> `PutItem` 은 book 앱만 허용 → 채점 3-3(비-book PutItem → AccessDenied) 통과.
> ✅ **채점 3-1** GSI · ✅ **3-2** db-key 암호화 · ✅ **3-3** 쓰기 제한

---

# 6️⃣ IAM 역할

> **콘솔 경로:** `IAM → 역할 → 역할 생성`

### 6-1. EKS 클러스터 역할 `gj2026-eks-cluster-role`
- 신뢰 주체: `eks.amazonaws.com`
- 연결 정책: `AmazonEKSClusterPolicy`

### 6-2. 노드 역할 2개
`gj2026-eks-addon-node-role`, `gj2026-eks-app-node-role`
- 신뢰 주체: `ec2.amazonaws.com`
- 연결 정책: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore`

<details><summary>📄 두 노드역할 공통 인라인 (pull-through 캐시 권한)</summary>

```json
{ "Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Action":["ecr:CreateRepository","ecr:BatchImportUpstreamImage"],
  "Resource":"arn:aws:ecr:ap-northeast-2:<ACCOUNT_ID>:repository/ecr-public/*" }]}
```
</details>

<details><summary>📄 app 노드역할에만 추가 인라인 (DynamoDB/KMS)</summary>

```json
{ "Version":"2012-10-17","Statement":[
  { "Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:GetItem","dynamodb:Query","dynamodb:Scan"],
    "Resource":["arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/books",
                "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/books/index/*"] },
  { "Effect":"Allow","Action":["kms:Encrypt","kms:Decrypt","kms:GenerateDataKey*","kms:DescribeKey"],
    "Resource":"<db-key ARN>" }]}
```
</details>

### 6-3. Lambda 역할 `gj2026-lambda-role`
- 신뢰 주체: `lambda.amazonaws.com`
- 인라인: DynamoDB `GetItem/Query/Scan`(books+index), KMS `Decrypt/DescribeKey`(db-key),
  `cloudwatch:PutMetricData`(*), 로그 3종(`arn:aws:logs:*:*:*`)

### 6-4. Bastion 역할(선택) `gj2026-bastion-role`
- 신뢰 `ec2.amazonaws.com`, 정책 `AdministratorAccess` — 구축용 점프박스에 붙이면 편함.

> IRSA 역할 4종은 **EKS OIDC 등록 후**(7-2) 만든다 → 7-4.

---

# 7️⃣ EKS 클러스터 + OIDC + IRSA — 4번(6.5점)의 뼈대

### 7-1. 클러스터 생성
`EKS → 클러스터 생성`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-eks-cluster` |
| 버전 | **1.35** |
| 클러스터 역할 | `gj2026-eks-cluster-role` |
| Secrets 암호화 | KMS `alias/gj2026-eks-key` |
| VPC / 서브넷 | gj2026-vpc / a·b |
| 엔드포인트 액세스 | **퍼블릭 + 프라이빗** |
| 인증 모드 | **API_AND_CONFIG_MAP** |

생성 ~10분. → ✅ **채점 4-1** 클러스터 이름·버전·엔드포인트·eks-key

### 7-2. OIDC 공급자 등록
클러스터 `개요` 의 **OpenID Connect 공급자 URL** 복사 →
`IAM → 자격 증명 공급자 → 공급자 추가 → OpenID Connect`
- 공급자 URL: 위 issuer / 대상: `sts.amazonaws.com`

### 7-3. IRSA 역할 4종 (웹 자격 증명)
`IAM → 역할 생성 → 웹 자격 증명` (공급자 = 위 OIDC, Audience = sts.amazonaws.com).
신뢰정책 `sub` 를 각 ServiceAccount 로 지정:

| 역할 | `sub` (ServiceAccount) | 권한 |
|---|---|---|
| `gj2026-book-app-role` | `system:serviceaccount:skills:book-sa` | DynamoDB RW(books+index)+KMS db-key |
| `gj2026-grafana-role` | `system:serviceaccount:monitoring:grafana` | `CloudWatchReadOnlyAccess` |
| `AmazonEKSLoadBalancerControllerRole` | `system:serviceaccount:kube-system:aws-load-balancer-controller` | `ElasticLoadBalancingFullAccess`(+ LBC 공식 정책 권장) |
| `FluentBitRole` | `system:serviceaccount:logging:fluent-bit-sa` | `CloudWatchLogsFullAccess` |

<details><summary>📄 신뢰정책 예 (book-app-role)</summary>

```json
{ "Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Federated":"arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/<OIDC_ID>"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{
    "oidc.eks.ap-northeast-2.amazonaws.com/id/<OIDC_ID>:sub":"system:serviceaccount:skills:book-sa",
    "oidc.eks.ap-northeast-2.amazonaws.com/id/<OIDC_ID>:aud":"sts.amazonaws.com"}}}]}
```
</details>

> ⚠️ **가장 흔한 실수:** SA 어노테이션의 role ARN 에 계정번호를 잘못/누락하면 IRSA 전체가 깨져
> LBC 가 타겟을 못 붙이고 webhook 이 timeout 난다. 반드시 실제 `<ACCOUNT_ID>` 로.

> 노드그룹 생성은 **13-B**(bootstrap 이미지 + 런치템플릿 + aws-auth)에서. 노드 이름 규칙
> `gj2026.<instance_id>.<role>.node` 때문에 CloudShell 작업이 필요.

---

# 8️⃣ S3 정적 호스팅 — 2.0점

`S3 → 버킷 생성`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-static-<비번호>` |
| 퍼블릭 액세스 | **모두 차단** 유지 |
| 기본 암호화 | SSE-KMS `alias/gj2026-s3-key`, **버킷 키 활성화** |

- 콘텐츠를 **루트에** 업로드: `index.html`, `main.jpeg`
- 버킷 정책은 CloudFront 배포 ID 확정 후(12번) 추가:

<details><summary>📄 S3 버킷 정책 (OAC)</summary>

```json
{ "Version":"2012-10-17","Statement":[{
  "Sid":"AllowCloudFront","Effect":"Allow",
  "Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"s3:GetObject",
  "Resource":"arn:aws:s3:::gj2026-static-<비번호>/*",
  "Condition":{"ArnLike":{"AWS:SourceArn":"arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"}}}]}
```
</details>

> ✅ **채점 6-1** index.html·main.jpeg 루트 · ✅ **6-2** s3-key 암호화

---

# 9️⃣ ALB + 타겟그룹 — 1.0점

### 9-1. ALB 보안그룹 `gj2026-alb-sg`
| 방향 | 규칙 |
|---|---|
| 인바운드 | `HTTP 80` ← `10.0.0.0/16` |
| 인바운드 | `HTTP 80` ← **접두사 목록** `com.amazonaws.global.cloudfront.origin-facing` |
| 아웃바운드 | 전체 허용 |

### 9-2. 타겟그룹 2개
`EC2 → 대상 그룹 → 생성` (대상 유형 **IP**, VPC gj2026-vpc, 대상 등록 안 함)

| 이름 | 포트 | 상태검사 경로 |
|---|:-:|---|
| `gj2026-book-tg` | 8080 | `/health` |
| `gj2026-grafana-tg` | 3000 | `/grafana/api/health` |

### 9-3. ALB 생성
`EC2 → 로드 밸런서 → Application Load Balancer`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-alb` |
| 체계 | **Internal(내부)** |
| 서브넷 | a·b |
| 보안그룹 | `gj2026-alb-sg` |
| 교차 영역 LB | **활성화** |
| 리스너 HTTP:80 | 기본 → `gj2026-book-tg` |
| 규칙(우선순위1) | 경로 `/grafana*` → `gj2026-grafana-tg` |

### 9-4. 클러스터 SG 인바운드 추가
자동 생성된 `eks-cluster-sg-gj2026-...` 에:
- `TCP 8080` ← `gj2026-alb-sg`
- `TCP 3000` ← `gj2026-alb-sg`

> ✅ **채점 5-1** ALB **internal** + gj2026-vpc

---

# 🔟 Lambda — 1.0점

`Lambda → 함수 생성`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-book-reservation` |
| 런타임 | **Python 3.14** |
| 실행 역할 | `gj2026-lambda-role` |
| 환경 변수 | `TABLE_NAME = books` |
| 핸들러 | `lambda_function.lambda_handler` |

- `lambda_function.py` 업로드(배포)
- **함수 URL 생성** → 인증 유형 **NONE**
- 코드는 GET 2종(`/reservation`, `?client_id=`) 처리 + client_id 별 `BookReservation/InvocationCount` 메트릭(전체는 `ALL`)

> ✅ **채점 7-1** 함수 이름·런타임·Active

---

# 1️⃣1️⃣ WAF — 3.0점 (⚠️ 글로벌 / us-east-1)

`WAF & Shield → Web ACL → 리전 **Global (CloudFront)** → 생성`

| 항목 | 값 |
|---|---|
| 이름 | `gj2026-waf-acl` |
| 기본 동작 | Allow |
| 커스텀 응답 본문 | `method-not-allowed`="Method Not Allowed", `access-denied`="Access Denied" |

### 규칙1 `block-non-post-methods` (우선순위 1) → Block 405
**AND**:
- URI path **STARTS_WITH** `/v1/book`
- **NOT** ( HTTP method **EXACTLY** `POST` )
- 동작: Block → 커스텀 응답 **405**, 본문키 `method-not-allowed`

### 규칙2 `validate-client-id` (우선순위 2) → Block 403
**AND**:
- Query string **CONTAINS** `client_id`
- **NOT** ( Query string(**URL_DECODE**) **정규식 일치** `client_id=[A-Za-z][A-Za-z0-9]*[0-9][A-Za-z0-9]*(&|$)` )
- 동작: Block → 커스텀 응답 **403**, 본문키 `access-denied`

> 정규식 = **영문자로 시작 + 뒤에 숫자 포함**. `C001` 허용 / `123abc`·`Cabc`·`C@001`·`홍길동` 차단.
> ✅ **채점 9-1** 405 Method Not Allowed · ✅ **9-2** 403 Access Denied ×3

---

# 1️⃣2️⃣ CloudFront — 5.5점

### 12-1. OAC (S3용)
`CloudFront → 원본 액세스 → 컨트롤 생성` → `gj2026-s3-oac`, SigV4, **always**

### 12-2. VPC Origin (ALB용)
`CloudFront → VPC 원본 → 생성` → 이름 `gj2026-alb-origin`, 원본 = `gj2026-alb`, HTTP80/HTTPS443, **http-only**, TLSv1.2

### 12-3. 배포 생성
`CloudFront → 배포 생성`

| 항목 | 값 |
|---|---|
| 설명/이름 | `gj2026-cdn` |
| 기본 루트 객체 | `index.html` |
| Web ACL | `gj2026-waf-acl` |
| 뷰어 프로토콜 | **Redirect HTTP to HTTPS** |

**오리진 3개:**
| 오리진 ID | 도메인 | 설정 |
|---|---|---|
| `s3` | 버킷 리전 도메인 | OAC `gj2026-s3-oac` |
| `alb` | ALB DNS | **VPC 오리진** `gj2026-alb-origin` |
| `lambda` | 함수 URL 도메인(`https://`·`/` 제거) | 커스텀, https-only, TLSv1.2 |

**동작(Behaviors):**
| 경로 패턴 | 오리진 | 캐시 정책 | 메서드 | 오리진요청정책 |
|---|---|---|---|---|
| `Default (*)` | s3 | **CachingOptimized** | GET,HEAD | – |
| `/v1*` | alb | **CachingDisabled** | ALL | **AllViewer** |
| `/grafana*` | alb | CachingDisabled | ALL | AllViewer |
| `/reservation*` | lambda | CachingDisabled | GET,HEAD | **AllViewerExceptHostHeader** |

- 배포 생성 후 **`<DIST_ID>`** 로 8번 S3 버킷정책 / 1번 KMS 정책 채우기.
- 확장자 없는 URL → index.html: 기본 루트 객체로 처리(필요 시 CloudFront Function 보강).

> ✅ **채점 8-1** 캐싱(Miss/Miss/Hit) · **8-2** POST book · **8-3/8-4** 조회 · HTTP→HTTPS

---

# 1️⃣3️⃣ CloudShell — 이미지 빌드/푸시 · 노드그룹 · 앱 배포

콘솔 우상단 **CloudShell** 실행:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2 ; REG=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
aws ecr get-login-password --region $REGION | docker login -u AWS --password-stdin $REG
aws eks update-kubeconfig --name gj2026-eks-cluster --region $REGION
```

### 13-A. book 이미지 (≤ 3MB)
`Dockerfile` 은 멀티스테이지 + `upx -9` 압축(브루트 X — 빌드 시간 단축).

```bash
docker build --platform linux/amd64 -t $REG/book:latest application/
docker push $REG/book:latest      # → 2.5MB 정도
```

### 13-B. bootstrap 이미지 + 노드그룹 (노드 이름 규칙) — 채점 4-3
1. Bottlerocket **bootstrap 컨테이너** 이미지를 `gj2026-bootstrap` 로 푸시.
2. **런치템플릿 2개**(addon/app): user-data(TOML)에 bootstrap 이미지 지정,
   `user-data`=base64(`addon`/`app`)로 역할 구분 → hostname `gj2026.<id>.<role>.node`.
   ⚠️ LT 에 `image_id` 넣지 말 것(→ amiType CUSTOM, 채점 BOTTLEROCKET 불일치).
3. **aws-auth ConfigMap** 적용:

<details><summary>📄 aws-auth mapRoles</summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: aws-auth, namespace: kube-system }
data:
  mapRoles: |
    - rolearn: arn:aws:iam::<ACCOUNT_ID>:role/gj2026-eks-addon-node-role
      username: system:node:gj2026.{{SessionName}}.addon.node
      groups: [system:bootstrappers, system:nodes]
    - rolearn: arn:aws:iam::<ACCOUNT_ID>:role/gj2026-eks-app-node-role
      username: system:node:gj2026.{{SessionName}}.app.node
      groups: [system:bootstrappers, system:nodes]
```
</details>

4. **노드그룹 2개 생성** (`EKS → 노드그룹`, 커스텀 런치템플릿):

| 노드그룹 | AMI | 타입 | 수 | 라벨 |
|---|---|---|:-:|---|
| `gj2026-eks-addon-nodegroup` | Bottlerocket x86_64 | t3.medium | 2 | role=addon |
| `gj2026-eks-app-nodegroup` | Bottlerocket x86_64 | m5.large | 2 | role=app |

5. 노드 Ready 후 kubelet-serving CSR 승인:
```bash
kubectl get csr -o name | xargs -r kubectl certificate approve
```
> ✅ **채점 4-2** 노드그룹(AMI·타입·수) · **4-3** 노드 이름 규칙

### 13-C. 외부 이미지 미러링
```bash
mirror(){ docker pull $1; docker tag $1 $REG/$2; aws ecr create-repository --repository-name ${2%%:*} 2>/dev/null||true; docker push $REG/$2; }
mirror grafana/grafana:12.3.1                       grafana:12.3.1
mirror amazon/aws-for-fluent-bit:latest             aws-for-fluent-bit:latest
mirror public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0  aws-load-balancer-controller:v3.4.0
mirror public.ecr.aws/nginx/nginx:latest            ecr-public/nginx/nginx:latest
```

### 13-D. 네임스페이스 + LBC + book 배포
```bash
kubectl apply -f manifests/namespace.yaml

# LBC IRSA SA + helm (mservice webhook 끔 → cert 이슈 예방)
kubectl create sa aws-load-balancer-controller -n kube-system
kubectl annotate sa aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole --overwrite
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=gj2026-eks-cluster --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=$REG/aws-load-balancer-controller --set image.tag=v3.4.0 \
  --set enableServiceMutatorWebhook=false
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system

# book SA(IRSA) + 배포
kubectl create sa book-sa -n skills
kubectl annotate sa book-sa -n skills \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-book-app-role --overwrite
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" manifests/book.yaml | kubectl apply -f -

# 타겟그룹 바인딩 (ARN 채워서)
BOOK_TG=$(aws elbv2 describe-target-groups --names gj2026-book-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
GRAF_TG=$(aws elbv2 describe-target-groups --names gj2026-grafana-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
sed -e "s|PLACEHOLDER_BOOK_TG|$BOOK_TG|g" -e "s|PLACEHOLDER_GRAFANA_TG|$GRAF_TG|g" manifests/ingress.yaml | kubectl apply -f -

kubectl apply -f manifests/network-policy.yaml
```
> ✅ **채점 4-4** book Deployment 2/2 · **4-5** NetworkPolicy(ALB만 8080)

---

# 1️⃣4️⃣ Monitoring — 3.0점

### 14-A. Grafana (helm, ns monitoring)
```bash
kubectl create sa grafana -n monitoring
kubectl annotate sa grafana -n monitoring \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-grafana-role --overwrite
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" manifests/grafana-values.yaml > /tmp/gv.yaml
helm upgrade --install grafana grafana/grafana -n monitoring -f /tmp/gv.yaml
kubectl apply -f manifests/grafana.yaml
```
[`manifests/grafana-values.yaml`](manifests/grafana-values.yaml) 핵심:
- `adminPassword: Skills53#`, `serve_from_sub_path`+`root_url=.../grafana`, nodeSelector role=addon
- **CloudWatch 데이터소스**(authType default, region ap-northeast-2)
- **대시보드 `WSI Dashboard`** — `BookReservation/InvocationCount` 를 client_id 별 + `ALL` 시각화
- `downloadDashboardsImage` 를 **ECR grafana 이미지**로(docker.io curl 접근 불가 대응)

### 14-B. Fluent Bit (DaemonSet, ns logging)
```bash
kubectl create sa fluent-bit-sa -n logging
kubectl annotate sa fluent-bit-sa -n logging \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/FluentBitRole --overwrite
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" manifests/fluentbit.yaml | kubectl apply -f -
```
[`manifests/fluentbit.yaml`](manifests/fluentbit.yaml) 핵심:
- book 로그 tail → `remote_addr` 파싱 → rewrite_tag 로 AZ 분리(`^10\.0\.10\.`→a, `^10\.0\.11\.`→b)
- Log Group `/eks/book-svc/access`, Stream `/book-svc/ap-northeast-2a`·`.../2b`
- **`log_key` 미사용** → 레코드를 JSON(`{"remote_addr":"10.0.x.x"}`)으로 전송(채점 `jq .remote_addr` 파싱)
- DaemonSet 이름 `aws-for-fluent-bit`

> ✅ **채점 10-1** AZ별 로그 스트림 IP 분리 · **10-2** Grafana WSI Dashboard(수동)

---

# 1️⃣5️⃣ 최종 점검 + 채점 직전 정리

```bash
CF=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='gj2026-cdn'].DomainName" --output text)

curl -s -o /dev/null -w "%{http_code} %header{x-cache}\n" https://$CF/            # 200 Miss
curl -s -o /dev/null -w "%{http_code} %header{x-cache}\n" https://$CF/index.html  # 200 Hit(2회)
curl -X POST -H "Content-Type: application/json" \
  -d '{"client_id":"C001","username":"Alice","email":"a@a.com","concert_name":"x"}' https://$CF/v1/book
curl "https://$CF/reservation?client_id=C001"
curl -s -w " %{http_code}\n" https://$CF/v1/book                        # Method Not Allowed 405
curl -s -w " %{http_code}\n" "https://$CF/reservation?client_id=123abc"  # Access Denied 403
echo https://$CF/grafana    # admin / Skills53#
```

### 🧹 채점 직전 (필수)
```bash
# 1) DynamoDB books 비우기 (데이터 0건이어야 채점 통과)
aws dynamodb scan --table-name books --region ap-northeast-2 \
  --projection-expression booking_id --query "Items[].booking_id.S" --output text \
| tr '\t' '\n' | while read -r id; do [ -n "$id" ] && \
  aws dynamodb delete-item --table-name books --region ap-northeast-2 \
  --key "{\"booking_id\":{\"S\":\"$id\"}}"; done

# 2) 이전 채점 잔여 nginx-test 삭제 (4-5 NetworkPolicy 대비)
kubectl delete pod nginx-test -n skills --ignore-not-found
```

---

## 📎 매니페스트

| 파일 | 용도 |
|---|---|
| [`manifests/namespace.yaml`](manifests/namespace.yaml) | skills·monitoring·logging |
| [`manifests/book.yaml`](manifests/book.yaml) | book Deployment(2)·Service |
| [`manifests/ingress.yaml`](manifests/ingress.yaml) | TargetGroupBinding(book·grafana) |
| [`manifests/network-policy.yaml`](manifests/network-policy.yaml) | book = ALB만 8080 허용 |
| [`manifests/grafana.yaml`](manifests/grafana.yaml) | grafana-svc |
| [`manifests/grafana-values.yaml`](manifests/grafana-values.yaml) | helm values(CloudWatch·WSI Dashboard) |
| [`manifests/fluentbit.yaml`](manifests/fluentbit.yaml) | ConfigMap + DaemonSet |

> 동일 구성의 IaC 는 상위 [`../../05/1과제`](../../05/1과제) Terraform 참고(값 1:1 대응).
