# 🏆 제61회 인천기능경기대회 클라우드컴퓨팅 제1과제 — AWS 콘솔 풀이 (처음부터 끝까지)

> 과제지 **v5** + 채점기준표 **v2** 기준 **콘솔 클릭 순서** 가이드.
> 리전은 전부 **서울(ap-northeast-2)**, **WAF·WAF로그·platform 복제키만 글로벌(us-east-1)**.
> 문서 안의 `<선수등번호>`, `<ACCOUNT_ID>`, `<DIST_ID>` 는 본인 값으로 바꿔 입력.
> 이름·태그·변수는 **대소문자까지 정확히**.

---

## 📋 진행 순서 한눈에

```
1. VPC 네트워크      → 2. VPC 엔드포인트      → 3. KMS 키 3개
   ↓
4. S3               → 5. DynamoDB           → 6. ECR
   ↓
7. IAM(Audit Role)  → 8. Lambda             → 9. EKS 클러스터
   ↓
10. bastion/CloudShell: 이미지 빌드·push · 노드그룹 · kubectl · helm
   ↓
11. ALB(Internal)   → 12. WAF(글로벌)        → 13. CloudFront
   ↓
14. Grafana ALB + 대시보드 → 15. CloudShell(unicorn-mark) 채점 준비
```

## 🎯 배점 체크리스트 (총 30점)

| # | 주요항목 | 배점 | 완료 |
|:-:|---|:-:|:-:|
| 1 | Networking | 3.0 | ☐ |
| 2 | KMS | 1.0 | ☐ |
| 3 | S3 | 1.0 | ☐ |
| 4 | Database | 1.5 | ☐ |
| 5 | ECR | 1.0 | ☐ |
| 6 | EKS | 4.5 | ☐ |
| 7 | Lambda | 1.0 | ☐ |
| 8 | Service Endpoint | 7.0 | ☐ |
| 9 | Security | 2.0 | ☐ |
| 10 | Application | 1.5 | ☐ |
| 11 | Observability | 2.0 | ☐ |
| 12 | Runtime Test | 3.0 | ☐ |
| 13 | Grafana | 1.5 | ☐ |
| | **합계** | **30** | |

## 🧰 준비물

- AWS 콘솔 로그인(관리자급) + **CloudShell**(우상단 `>_`)
- 배포파일: `book`(바이너리), `Dockerfile`, `index.html`, `lambda` 코드
- k8s 매니페스트 → `2026-terraform/06/1과제/manifest/` 재사용
- 계정 ID(`<ACCOUNT_ID>`) 미리 확인

> 💡 EKS 내부 리소스(Deployment·Service·로그·모니터링)는 콘솔로 못 만든다.
> **인프라는 콘솔**, **이미지 빌드·kubectl·helm 은 bastion 또는 CloudShell** 로 진행.

---

# 1️⃣ Networking (배점 3.0)

> **콘솔 경로:** `VPC`

### 1-1. VPC
`VPC → VPC 생성 → "VPC만"`

| 항목 | 값 |
|---|---|
| 이름 태그 | `unicorn-vpc` |
| IPv4 CIDR | `10.97.0.0/16` |

생성 후 → `작업 → VPC 설정 편집` → **DNS 호스트 이름 활성화** ✅

### 1-2. 서브넷 6개
`VPC → 서브넷 → 서브넷 생성` (VPC: `unicorn-vpc`)

| 이름 | AZ | CIDR |
|---|---|---|
| `unicorn-subnet-pub-a` | 2a | `10.97.0.0/24` |
| `unicorn-subnet-pub-b` | 2b | `10.97.1.0/24` |
| `unicorn-subnet-pub-c` | 2c | `10.97.2.0/24` |
| `unicorn-subnet-priv-a` | 2a | `10.97.10.0/24` |
| `unicorn-subnet-priv-b` | 2b | `10.97.11.0/24` |
| `unicorn-subnet-priv-c` | 2c | `10.97.12.0/24` |

> 📌 CIDR 순서: **Public 0·1·2**, **Private 10·11·12** (VPC CIDR 기준 n번째).
> pub 3개는 `서브넷 설정 편집 → 퍼블릭 IPv4 자동 할당` ✅

### 1-3. IGW
`VPC → 인터넷 게이트웨이 → 생성` → 이름 `unicorn-igw` → `작업 → VPC에 연결` → `unicorn-vpc`

### 1-4. NAT 게이트웨이 3개 (AZ별)
`VPC → NAT 게이트웨이 → 생성` ×3

| 이름 | 서브넷 | EIP |
|---|---|---|
| `unicorn-nat-a` | pub-a | 새 EIP (`unicorn-eip-nat-a`) |
| `unicorn-nat-b` | pub-b | 새 EIP (`unicorn-eip-nat-b`) |
| `unicorn-nat-c` | pub-c | 새 EIP (`unicorn-eip-nat-c`) |

### 1-5. 라우팅 테이블
`VPC → 라우팅 테이블`

| 이름 | `0.0.0.0/0` 대상 | 연결 서브넷 |
|---|---|---|
| `unicorn-rt-pub` | `unicorn-igw` | pub-a, pub-b, pub-c (공용) |
| `unicorn-rt-priv-a` | `unicorn-nat-a` | priv-a |
| `unicorn-rt-priv-b` | `unicorn-nat-b` | priv-b |
| `unicorn-rt-priv-c` | `unicorn-nat-c` | priv-c |

### 1-6. VPC Flow Log
1. `CloudWatch → 로그 그룹 → 생성` → `/aws/vpc-flow-log/unicorn-vpc`
2. `VPC → unicorn-vpc → 흐름 로그 탭 → 흐름 로그 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-flow-log` |
| 필터 | **모두(All)** |
| 대상 | CloudWatch Logs → `/aws/vpc-flow-log/unicorn-vpc` |
| IAM 역할 | 신규 생성(마법사) |

### ✅ 채점 포인트
- [ ] VPC CIDR `10.97.0.0/16`, 서브넷 6개 전부 `/24`
- [ ] pub→igw / priv→AZ별 nat, 라우팅 테이블 4개(pub 1 + priv 3)
- [ ] Flow Log 활성(1개 이상)

---

# 2️⃣ VPC 엔드포인트 (Networking 포함)

> 앱(Private)이 이미지 pull·로그를 **인터넷 안 거치고** 처리하도록.

### 2-1. 엔드포인트용 SG
`EC2 → 보안 그룹 → 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-vpc-vpce-sg` |
| 인바운드 | HTTPS 443 ← `10.97.0.0/16` |
| 아웃바운드 | 전체 허용 |

### 2-2. 엔드포인트 3개
`VPC → 엔드포인트 → 생성`

| 서비스 | 유형 | 설정 |
|---|---|---|
| `...ap-northeast-2.s3` | Gateway | 라우팅 테이블 priv-a/b/c |
| `...ap-northeast-2.ecr.api` | Interface | priv-a/b/c, SG=vpce-sg, 프라이빗 DNS ✅ |
| `...ap-northeast-2.ecr.dkr` | Interface | priv-a/b/c, SG=vpce-sg, 프라이빗 DNS ✅ |

### ✅ 채점 포인트
- [ ] s3 / ecr.api / ecr.dkr 엔드포인트 존재

---

# 3️⃣ KMS 키 3개 (배점 1.0)

> **콘솔 경로:** `KMS → 고객 관리형 키 → 키 생성` (전부 대칭 / 암호화·복호화)
> 세 키 모두 생성 후 **키 회전 켜기 · 주기 90일**.

| 별칭 | 용도 | 특이사항 |
|---|---|---|
| `unicorn-kms-app` | Secrets Manager, DynamoDB | |
| `unicorn-kms-data` | S3, ECR | |
| `unicorn-kms-platform` | EKS Secrets, EBS, Log | **다중 리전 키** |

### 🔑 platform 키 추가 작업
1. 키 정책에 CloudWatch Logs 허용 추가:

<details><summary>📄 platform 키 정책 추가분 (펼치기)</summary>

```json
{
  "Sid": "AllowCloudWatchLogs",
  "Effect": "Allow",
  "Principal": { "Service": "logs.ap-northeast-2.amazonaws.com" },
  "Action": ["kms:Encrypt","kms:Decrypt","kms:GenerateDataKey*","kms:DescribeKey"],
  "Resource": "*"
}
```
</details>

2. **us-east-1 복제** (WAF 로그 암호화용):
   리전 → 버지니아(us-east-1) → `KMS → unicorn-kms-platform → 키 작업 → 다른 리전으로 복제` → 별칭 `unicorn-kms-platform`

### ✅ 채점 포인트
- [ ] 3개 키 전부 회전 True / 90일
- [ ] platform = 다중 리전 + us-east-1 복제본

---

# 4️⃣ S3 (배점 1.0)

> **콘솔 경로:** `S3 → 버킷 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-web-<ACCOUNT_ID>` |
| 퍼블릭 액세스 | **모두 차단** ✅ |
| 버전 관리 | **활성화** |
| 암호화 | SSE-KMS → `unicorn-kms-data`, 버킷 키 ✅ |

### ✅ 채점 포인트
- [ ] 퍼블릭 4종 차단, 버전관리 Enabled, aws:kms(data 키)

---

# 5️⃣ DynamoDB (배점 1.5)

> **콘솔 경로:** `DynamoDB → 테이블 생성`

| 항목 | 값 |
|---|---|
| 테이블 이름 | `unicorn-concert-db` |
| 파티션 키 | `booking_id` (String) |
| 용량 모드 | **온디맨드(PAY_PER_REQUEST)** |
| 암호화 | 고객관리형 KMS → `unicorn-kms-app` |

**GSI 추가**

| 항목 | 값 |
|---|---|
| 이름 | `client-id-created-at-index` |
| 파티션 키 | `client_id` (String) |
| 정렬 키 | `created_at` (String) |
| 프로젝션 | **ALL** |

생성 후 `추가 설정`: **PITR 켜기**, **삭제 방지 켜기**

### ✅ 채점 포인트
- [ ] PAY_PER_REQUEST / booking_id / GSI(client_id·created_at·ALL) / app키 SSE / PITR / 삭제방지

---

# 6️⃣ ECR (배점 1.0)

> **콘솔 경로:** `ECR → 리포지토리 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-concert-app` |
| 태그 변경 불가 | **IMMUTABLE_WITH_EXCLUSION** (예외 `latest`) |
| 푸시 스캔 | **켜기** |
| 암호화 | KMS → `unicorn-kms-data` |

> ⚠️ 콘솔에서 IMMUTABLE_WITH_EXCLUSION 미지원 시 CLI:
> ```bash
> aws ecr put-image-tag-mutability --repository-name unicorn-concert-app \
>   --image-tag-mutability IMMUTABLE_WITH_EXCLUSION \
>   --image-tag-mutability-exclusion-filters "filterType=WILDCARD,filter=latest"
> ```
> 이미지 빌드/push(v1.0.0, latest)는 **10번(부트스트랩)** 에서.

### ✅ 채점 포인트
- [ ] scan on push / IMMUTABLE_WITH_EXCLUSION / KMS(data) / 태그 v1.0.0·latest / 취약점 0

---

# 7️⃣ IAM — Audit Role (Security, 배점 2.0)

> **콘솔 경로:** `IAM → 역할 → 역할 생성 → 사용자 지정 신뢰 정책`

| 항목 | 값 |
|---|---|
| 역할 이름 | `unicorn-audit-role` |
| 최대 세션 시간 | **1시간** |
| External ID | `unicorn-audit-2026<선수등번호>` |

<details><summary>📄 신뢰 정책 (펼치기)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:root" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "unicorn-audit-2026<선수등번호>" } }
  }]
}
```
</details>

<details><summary>📄 권한 정책(최소권한·와일드카드 금지) (펼치기)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["dynamodb:GetItem","dynamodb:Query"],
      "Resource": ["arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/unicorn-concert-db",
                   "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/unicorn-concert-db/index/*"] },
    { "Effect": "Allow", "Action": "ec2:DescribeVpcs", "Resource": "*" },
    { "Effect": "Allow", "Action": ["eks:DescribeCluster","eks:DescribeNodegroup","eks:DescribeAddon"],
      "Resource": "arn:aws:eks:ap-northeast-2:<ACCOUNT_ID>:cluster/unicorn-eks-cluster" }
  ]
}
```
</details>

### ✅ 채점 포인트
- [ ] ExternalId 없거나 틀리면 Assume 거부 / 세션 1시간 / describe 권한만 / `*` 없음

---

# 8️⃣ Lambda (배점 1.0)

> **콘솔 경로:** `Lambda → 함수 생성`

1. `CloudWatch → 로그 그룹 → 생성` → `/unicorn/lambda/get-booking`
2. 함수 생성

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-get-booking-func` |
| 런타임 | Python 3.12 |
| 환경변수 | `TABLE_NAME=unicorn-concert-db` |
| VPC | `unicorn-vpc`, priv-a/b/c, 새 SG(egress 전체) |
| 환경변수 암호화 | `unicorn-kms-platform` |

실행 역할 권한: DynamoDB(GetItem/Query) + Logs 쓰기 + ENI(ec2 Create/Describe/Delete NetworkInterface) + KMS Decrypt/GenerateDataKey

### ✅ 채점 포인트
- [ ] 함수명 / platform KMS / 로그그룹 `/unicorn/lambda/get-booking`

---

# 9️⃣ EKS 클러스터 (배점 4.5)

> ⚠️ secrets 암호화·로그 5종·노드 라벨/태그·프라이빗 엔드포인트를 정확히 맞추려면
> **eksctl(10번 부록)** 을 강력 권장. 콘솔로 할 경우 아래.

### 9-1. 클러스터
`EKS → 클러스터 추가 → 생성`

| 항목 | 값 |
|---|---|
| 이름 / 버전 | `unicorn-eks-cluster` / **1.35** |
| Secrets 암호화 | KMS `unicorn-kms-platform` |
| 네트워크 | `unicorn-vpc`, priv-a/b/c |
| 엔드포인트 | **프라이빗만** (퍼블릭 OFF) |
| 제어플레인 로깅 | **5종 전체** (api·audit·authenticator·controllerManager·scheduler) |
| 인증 모드 | **API** (Access Entry, aws-auth 미사용) |

### 9-2. 노드그룹 2개

| 노드그룹 | 인스턴스 | 수 | 레이블 | EC2 이름 태그 |
|---|---|---|---|---|
| `app-ng` | t3.medium | 2~3 | `unicorn=app` | `unicorn-k8snode-app-node` |
| `addon-ng` | t3.medium | 1~2 | `unicorn=addon` | `unicorn-k8snode-addon-node` |

- 서브넷 priv-a/b/c(HA), EBS 볼륨 암호화 `unicorn-kms-platform`

### 9-3. 애드온
`vpc-cni`, `coredns`, `kube-proxy`, **`eks-pod-identity-agent`**

### 9-4. Pod Identity (Book App)
IAM 역할 `unicorn-book-app-role`:

<details><summary>📄 신뢰 정책 (펼치기)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole","sts:TagSession"],
    "Condition": { "ArnEquals": { "aws:SourceArn":
      "arn:aws:eks:ap-northeast-2:<ACCOUNT_ID>:cluster/unicorn-eks-cluster" } }
  }]
}
```
</details>

- 권한: DynamoDB(PutItem/GetItem/Query) on 테이블+index, KMS(app키) Decrypt/GenerateDataKey, Logs 쓰기
- `EKS → 클러스터 → 액세스 → Pod Identity 연결 생성`:
  네임스페이스 `unicorn`, SA `unicorn-book-app-sa`, 역할 `unicorn-book-app-role`

### ✅ 채점 포인트
- [ ] 버전 1.35 / 퍼블릭 false·프라이빗 true / 로그 5종 / secrets platform키 / 인증 API
- [ ] app 노드 2AZ 이상, addon 1+ / EC2 태그 / 노드 프라이빗

---

# 🔟 부트스트랩 (bastion SSM 또는 CloudShell)

> 이미지 빌드·push, eksctl(권장), kubectl apply, helm 을 한 번에.

```bash
export number=<선수등번호>
aws s3 cp s3://$(aws s3 ls | grep unicorn-manifest | awk '{print $3}')/ ./ --recursive
source apply.sh
```

`apply.sh` 자동 처리: 이미지 빌드/ECR push → ECR IMMUTABLE_WITH_EXCLUSION → eksctl 클러스터 →
kubectl apply(ns·sa·deploy·svc·**fluentd·fluent-bit**·grafana-dashboard) → Pod Identity →
ALB 타겟 등록 → helm(Prometheus/Grafana) → 권한.

> 매니페스트 수정 시: **로컬 terraform apply → CloudShell 재다운로드** 순서 필요.

### ✅ 채점 포인트 (Application 1.5 / Observability 2.0 / Runtime 3.0)
- [ ] Deployment `unicorn-book-app-deploy`(2/2), Service `unicorn-book-app-svc`(ClusterIP)
- [ ] liveness/readiness `/health`, preStop sleep 15, graceful 45
- [ ] 로그 `/unicorn/eks/book-app` JSON, `/health` 제외
- [ ] fluentd/fluent-bit 라벨에 `app` 키 금지(채점 `-l app` 이 book 파드만)

---

# 1️⃣1️⃣ ALB (Internal) — Service Endpoint (배점 7.0 일부)

> **콘솔 경로:** `EC2 → 로드밸런서 → ALB 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-alb` |
| 체계 | **Internal(내부)** |
| 네트워크 | `unicorn-vpc`, priv-a/b/c |
| SG | `unicorn-alb-sg` |
| 리스너 | HTTP 80 |

**대상 그룹**
| 이름 | 유형 | 포트 | 상태검사 |
|---|---|---|---|
| `unicorn-tg` | IP | 80 | `/health` |
| `unicorn-alb-lambda-tg` | Lambda | - | `unicorn-get-booking-func` 등록 |

**리스너 규칙**
| 우선순위 | 조건 | 대상 |
|---|---|---|
| 5 | path `/health` | `unicorn-tg` |
| 10 | method GET **AND** path `/v1/book` | Lambda TG |
| 기본 | 그 외(POST 등) | `unicorn-tg` |

### ✅ 채점 포인트
- [ ] internal·application·active, HTTP 80, GET→Lambda / POST·health→App

---

# 1️⃣2️⃣ WAF (글로벌 us-east-1)

> **콘솔 경로:** 리전 **us-east-1** → `WAF → Web ACL 생성` (리소스 유형 CloudFront)

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-waf` |
| 기본 동작 | **Allow** |

**규칙**
1. `AWSManagedRulesCommonRuleSet` (Override: **None**)
2. `AWSManagedRulesKnownBadInputsRuleSet` (Override: **None**)
3. `unicorn-rate-limit` — Rate-based, **60초 / 50건 초과 Block**,
   커스텀 응답 **403** 본문 `Request blocked by Unicorn WAF`

**로깅**: 로그 그룹 `aws-waf-logs-unicorn`(us-east-1), `unicorn-kms-platform`(복제키) 암호화

### ✅ 채점 포인트
- [ ] Common·KnownBad(None) / rate 60·50 / 403 문구 / 로그그룹 platform키 암호화

---

# 1️⃣3️⃣ CloudFront (Service Endpoint)

### 13-1. S3 OAC
`CloudFront → 원본 액세스 → 컨트롤 설정 생성` → 이름 `s3-oac`, SigV4/always

### 13-2. VPC Origin (ALB)
`CloudFront → VPC 오리진 → 생성` → 이름 `app-origin`, 원본 `unicorn-alb`, HTTP 80, http-only
→ 생성 시 서비스 SG `CloudFront-VPCOrigins-Service-SG*` 자동 생성

### 13-3. Distribution
`CloudFront → 배포 생성`

| 항목 | 값 |
|---|---|
| 설명(Comment) | `unicorn-svc-cf` |
| 원본1 (S3) | `unicorn-web-<ACCOUNT_ID>.s3...`, OAC=`s3-oac` |
| 원본2 (App) | VPC Origin `app-origin` |
| 기본 동작 | 대상 `app-origin`, redirect-to-https, GET~DELETE, 헤더/쿠키 전달 |
| 추가 동작 | `/static/*` → S3 오리진(캐싱) |
| WAF | `unicorn-waf` |

배포 후 **S3 버킷 정책** 추가:

<details><summary>📄 S3 버킷 정책 (OAC + Distribution ARN 조건) (펼치기)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipal",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::unicorn-web-<ACCOUNT_ID>/*",
    "Condition": { "StringEquals": {
      "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>" } }
  }]
}
```
</details>

### 13-4. ⚠️ ALB SG 인바운드 (과제 10-1)
`EC2 → SG unicorn-alb-sg → 인바운드 편집`:
- **HTTP 80, 소스 = `CloudFront-VPCOrigins-Service-SG*` 만** 허용
- **0.0.0.0/0 직접 인바운드 금지** → CloudShell 직접요청 시 000/403 나와야 득점(8-5)

### ✅ 채점 포인트
- [ ] 원본 2개(S3 OAC + app VPC origin), 버킷정책 이 Distribution만
- [ ] `/static/*` 캐싱, ALB는 CloudFront SG만 허용

---

# 1️⃣4️⃣ Grafana ALB + 대시보드 (배점 1.5)

### 14-1. Grafana ALB
`EC2 → ALB 생성`

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-grafana-alb` (**Internet-facing**) |
| 서브넷 | pub-a/b/c |
| SG | `unicorn-grafana-alb-sg` (인바운드 80 전체) |
| 대상그룹 | `unicorn-grafana-tg` (instance, HTTP **30300**, 검사 `/api/health`) |
| 리스너 | HTTP 80 → `unicorn-grafana-tg` (addon 노드 30300 등록) |

### 14-2. 접속 & 대시보드
- 브라우저 → `unicorn-grafana-alb` DNS
- 로그인 `skills<선수등번호>` / `HelloKrSkills!<선수등번호>@`
- 대시보드 `unicorn-grafana-dashboard`, 패널 5개:

| # | 패널 | 타입 | PromQL |
|:-:|---|---|---|
| 1 | EKS Node CPU Usage (%) | Time series | `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| 2 | EKS Node Memory Usage (%) | Time series | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| 3 | unicorn Namespace Pod Status | Stat | `sum by (phase) (kube_pod_status_phase{namespace="unicorn"})` |
| 4 | Book App Ready Pods | Stat | `count(kube_pod_status_ready{namespace="unicorn",condition="true",pod=~"unicorn-book-app.*"} == 1)` |
| 5 | Book App HTTP Request Duration | Time series | `quantile(0.95, rate(container_cpu_usage_seconds_total{namespace="unicorn",container="book"}[5m])) * 1000` |

> ⚠️ **No Data = 오답.** 패널별 datasource `Prometheus` 지정 확인.
> (grafana-dashboard.yaml ConfigMap 으로 자동 생성됨 — 부트스트랩 참고)

### ✅ 채점 포인트
- [ ] 5개 패널 타입·이름 일치, No Data 없음

---

# 1️⃣5️⃣ CloudShell (unicorn-mark) — 채점 준비

`CloudShell → VPC 환경 생성` (**채점은 여기서 진행**)

| 항목 | 값 |
|---|---|
| 이름 | `unicorn-mark` |
| VPC / 서브넷 | `unicorn-vpc` / **Private** 아무거나 |
| SG | `unicorn-mark-sg` (인·아웃 전체 허용) |

`unicorn-mark-sg`를 아래 SG 인바운드에 **소스**로 추가:
- `unicorn-vpc-vpce-sg`, Lambda SG, `unicorn-grafana-alb-sg`, EKS 클러스터 SG
- ⚠️ **`unicorn-alb-sg` 에는 추가 금지** (8-5 직접요청 거부)

---

# ✅ 최종 점검 (채점 직전)

- [ ] 실행 중인 부하/테스트 중지 (과제 유의 9번)
- [ ] 모든 이름·태그 대소문자 정확
- [ ] ap-northeast-2 리전 (WAF/복제키만 us-east-1)
- [ ] CloudShell `unicorn-mark` 에서 mark.sh 정상 동작
- [ ] Grafana 패널 No Data 없음
- [ ] ALB 직접요청 000/403, CloudFront 경유 정상 200

---

## 📎 부록 — 자주 틀리는 포인트

| 포인트 | 주의 |
|---|---|
| 서브넷 CIDR | Public 0·1·2 / Private 10·11·12 |
| KMS 회전 | 90일, platform는 다중리전 + us-east-1 복제 |
| ECR | IMMUTABLE_WITH_EXCLUSION(latest 예외), 취약점 0 |
| EKS | 엔드포인트 프라이빗 전용, 로그 5종, secrets platform키 |
| ALB | Internal + CloudFront SG만 80 (직접요청 거부) |
| WAF | 60초/50건, 403 `Request blocked by Unicorn WAF` |
| Audit Role | 세션 1시간, ExternalId, 와일드카드 금지 |
| fluentd 라벨 | `app` 키 금지 (`k8s-app` 사용) — 채점 `-l app` 오염 방지 |
| 로그 파이프라인 | fluent-bit → **fluentd** → CloudWatch (직행 아님) |
