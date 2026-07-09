# 제61회 인천기능경기대회 · 클라우드컴퓨팅 제1과제 — AWS 콘솔 수동 구축 가이드

> Terraform 없이 **AWS 콘솔(GUI)** 만으로 처음부터 끝까지 구축하는 절차서.
> 리전은 전부 **ap-northeast-2(서울)**. CloudFront/IAM은 글로벌.
> `<비번호>` = 본인 비번호(예: 101). 이름/태그는 대소문자까지 정확히 입력.
> 최종 목표: **CloudFront 단일 엔드포인트** → 정적페이지(S3) + `/v1/book` API(ALB→ECS Fargate→DynamoDB).

## 전체 순서 요약

1. VPC & 네트워킹 (VPC, 서브넷 4개, IGW, NAT, 라우팅, DynamoDB Endpoint)
2. 보안 그룹
3. KMS (DynamoDB용 CMK)
4. DynamoDB
5. S3 (정적 파일 업로드)
6. ECR (리포지토리 + 이미지 빌드/푸시 ← Bastion EC2)
7. IAM (Execution Role, Task Role)
8. CloudWatch (로그 그룹, 메트릭 필터, 알람)
9. ALB (Target Group, 리스너, 헤더 기반 차단)
10. ECS Fargate (Task Definition, Service)
11. CloudFront (OAC, S3 + ALB Origin, 라우팅)
12. 검증

> **핵심 의존성**: DynamoDB·KMS → S3 → ECR(이미지 푸시) → IAM → CloudWatch(로그그룹 먼저) → ALB → ECS → CloudFront
> ECS Task가 뜨려면 **ECR 이미지**와 **로그 그룹**이 먼저 있어야 합니다.

---

## 0. 사전 준비

- 콘솔 우상단 리전을 **서울(ap-northeast-2)** 로 설정.
- 계정 ID 확인: 우상단 계정 메뉴 → 12자리 숫자 기록 (`<ACCOUNT_ID>`).
- 지급파일 확인: `index.html`, `main.jpeg`, `book`(바이너리).

---

## 1. VPC & 네트워킹

### 1-1. VPC 생성
VPC 콘솔 → **VPC 생성** → "**VPC만**" 선택
- 이름 태그: `skills-book-vpc`
- IPv4 CIDR: `10.0.0.0/16`
- 생성 후 **작업 → VPC 설정 편집** → `DNS 호스트 이름 활성화` + `DNS 확인 활성화` 둘 다 체크

### 1-2. 서브넷 4개 생성
VPC → 서브넷 → **서브넷 생성** → VPC: `skills-book-vpc`

| 이름 | AZ | CIDR |
|---|---|---|
| skills-book-public-1 | ap-northeast-2a | 10.0.0.0/24 |
| skills-book-public-2 | ap-northeast-2b | 10.0.1.0/24 |
| skills-book-private-1 | ap-northeast-2a | 10.0.10.0/24 |
| skills-book-private-2 | ap-northeast-2b | 10.0.11.0/24 |

- public 2개는 각각 **작업 → 서브넷 설정 편집 → 퍼블릭 IPv4 자동 할당** 체크.

### 1-3. 인터넷 게이트웨이
VPC → 인터넷 게이트웨이 → **생성** → 이름 `skills-book-igw`
→ 생성 후 **작업 → VPC에 연결** → `skills-book-vpc`.

### 1-4. NAT 게이트웨이 (1개)
VPC → NAT 게이트웨이 → **생성**
- 이름: `skills-book-nat`
- 서브넷: `skills-book-public-1`
- 탄력적 IP: **새 EIP 할당**

> ⏳ NAT는 available 되기까지 1~2분 소요.

### 1-5. 라우팅 테이블

**퍼블릭 라우팅 테이블**
- **생성** → 이름 `skills-book-public-rt`, VPC `skills-book-vpc`
- 라우팅 편집 → `0.0.0.0/0` → 대상 `skills-book-igw`
- 서브넷 연결 편집 → public-1, public-2 연결

**프라이빗 라우팅 테이블**
- **생성** → 이름 `skills-book-private-rt`, VPC `skills-book-vpc`
- 라우팅 편집 → `0.0.0.0/0` → 대상 `NAT 게이트웨이` → `skills-book-nat`
- 서브넷 연결 편집 → private-1, private-2 연결

### 1-6. DynamoDB VPC Endpoint (Gateway)
VPC → 엔드포인트 → **엔드포인트 생성**
- 이름: `skills-book-dynamodb-endpoint`
- 서비스: `com.amazonaws.ap-northeast-2.dynamodb` (유형 **Gateway**)
- VPC: `skills-book-vpc`
- 라우팅 테이블: **`skills-book-private-rt` 체크**

> 채점 1-5는 Gateway 타입 + private 라우팅 연결을 확인합니다.

---

## 2. 보안 그룹

EC2 → 보안 그룹 → **보안 그룹 생성**
- 이름: `skills-book-sg`, VPC: `skills-book-vpc`
- 인바운드 규칙: **모든 트래픽 / 소스 0.0.0.0/0** (1줄)
- 아웃바운드 규칙: **모든 트래픽 / 0.0.0.0/0** (기본)

> 과제 요구가 "네트워킹 최소 구성"이라 SG 하나로 ALB·ECS 공용. 세밀하게 하려면 ALB SG / ECS SG 분리 가능하나 채점엔 무관.

---

## 3. KMS (DynamoDB CMK)

KMS 콘솔 → **키 생성**
- 키 유형: **대칭**, 용도: 암호화/복호화
- 별칭: `skills-book-ddb`
- 키 관리자/사용자: 본인 admin 계정
- 나머지 기본값으로 생성

> 채점 5-2는 `alias/skills-book-ddb` 존재 + CUSTOMER 관리형 + DynamoDB SSE 키 일치를 확인합니다.

---

## 4. DynamoDB

DynamoDB → **테이블 생성**
- 이름: `skills-book-booking`
- 파티션 키: `booking_id` (**문자열**)
- 설정: **사용자 지정** → 용량 모드 **온디맨드(PAY_PER_REQUEST)**
- 암호화: **고객 관리형 키(KMS)** → `alias/skills-book-ddb` 선택
- 생성

> client_id, username, email, concert_name, created_at 는 스키마 정의 불필요(NoSQL, 앱이 런타임에 기록).

---

## 5. S3 (정적 파일)

### 5-1. 버킷 생성
S3 → **버킷 생성**
- 이름: `skills-book-static-2026-<비번호>`  (예: `skills-book-static-2026-101`)
- 리전: ap-northeast-2
- **모든 퍼블릭 액세스 차단**: 4개 모두 체크(기본값 유지)
- 생성

### 5-2. 파일 업로드
버킷 → **업로드** → 지급파일 2개 추가:
- `index.html`  (콘텐츠 형식 text/html 자동)
- `main.jpeg`   (image/jpeg)

> 버킷 정책(OAC 허용)은 **11번 CloudFront 배포 생성 후** 설정합니다 (Distribution ARN이 필요하므로).

---

## 6. ECR + 이미지 빌드/푸시

콘솔에는 docker 빌드 기능이 없으므로 **Bastion EC2**를 잠깐 띄워서 빌드/푸시합니다.

### 6-1. ECR 리포지토리
ECR → **리포지토리 생성**
- 표시 여부: **프라이빗**
- 이름: `skills-book-app`
- 생성 후 → 리포지토리 선택 → **태그 편집** → Name = `skills-book-ecr` 추가
  (채점 4-1이 `Key=Name,Values=skills-book-ecr` 태그로 조회)

### 6-2. Bastion EC2 생성
EC2 → **인스턴스 시작**
- 이름: `skills-book-bastion`
- AMI: **Amazon Linux 2023**
- 인스턴스 유형: `t3.micro`
- 키 페어: 새로 생성(`skills-book-key`) 후 .pem 다운로드
- 네트워크: VPC `skills-book-vpc`, 서브넷 `skills-book-public-1`, **퍼블릭 IP 자동 할당 켜기**
- 보안 그룹: `skills-book-sg` 선택
- **고급 세부 정보 → IAM 인스턴스 프로파일**: 아래 6-3에서 만든 역할 지정
  (인스턴스 시작 전에 6-3 먼저 수행)

### 6-3. Bastion용 IAM Role
IAM → 역할 → **역할 생성**
- 신뢰 개체: **EC2**
- 권한 정책: `AmazonEC2ContainerRegistryFullAccess`
- 이름: `skills-book-bastion-role`
- 생성 후 6-2에서 이 역할을 인스턴스 프로파일로 지정

### 6-4. 이미지 빌드 & 푸시
Bastion에 SSH 접속 후 (지급 `book`, `Dockerfile` 을 scp 또는 붙여넣기로 배치):

```bash
# Dockerfile 내용 (book 바이너리와 같은 디렉터리)
# FROM amazonlinux:2023
# COPY book /app/book
# RUN chmod +x /app/book
# EXPOSE 8080
# CMD ["/app/book"]

sudo dnf install -y docker
sudo systemctl start docker

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region ap-northeast-2 \
  | sudo docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com

sudo docker build -t skills-book-app .
sudo docker tag skills-book-app:latest $ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/skills-book-app:latest
sudo docker push $ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/skills-book-app:latest
```

> ✅ 푸시 확인 후 **Bastion EC2는 종료(terminate)** 해도 됩니다. (채점 무관, 비용 절약)

---

## 7. IAM (ECS Role 2개)

### 7-1. Execution Role
IAM → 역할 → **역할 생성**
- 신뢰 개체: **AWS 서비스 → Elastic Container Service → Elastic Container Service Task**
- 권한: `AmazonECSTaskExecutionRolePolicy`
- 이름: `skills-book-ecs-execution-role`

### 7-2. Task Role
IAM → 역할 → **역할 생성**
- 신뢰 개체: **Elastic Container Service Task** (동일)
- 이름: `skills-book-ecs-task-role`
- 생성 후 → **인라인 정책 추가**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem","dynamodb:GetItem","dynamodb:Scan","dynamodb:Query"],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/skills-book-booking"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt","kms:GenerateDataKey"],
      "Resource": "<skills-book-ddb KMS 키 ARN>"
    }
  ]
}
```

> 채점 5-4는 Execution Role ≠ Task Role(둘이 서로 다름)을 확인합니다. 반드시 **2개 분리**.

---

## 8. CloudWatch (ECS 시작 전에 로그 그룹부터)

### 8-1. 로그 그룹
CloudWatch → 로그 그룹 → **생성**
- 이름: `/ecs/skills-book-app`
- 보존 기간: 7일(선택)

> ⚠️ ECS Task Definition의 awslogs 설정과 **이름이 정확히 일치**해야 컨테이너 로그가 쌓입니다.

### 8-2. 메트릭 필터 2개
로그 그룹 `/ecs/skills-book-app` → **메트릭 필터** 탭 → **메트릭 필터 생성**

Gin 앱 로그 형식 예: `[GIN] 2026/06/22 - 10:18:57 | 404 |  1.2ms | ...`

**4xx 필터**
- 필터 패턴: `"| 4"`
- 필터 이름: `skills-book-4xx-filter`
- 메트릭 네임스페이스: `Skills/CloudComputing/Task1`
- 메트릭 이름: `skills-book-4xx-count`
- 메트릭 값: `1`

**5xx 필터**
- 필터 패턴: `"| 5"`
- 필터 이름: `skills-book-5xx-filter`
- 네임스페이스: `Skills/CloudComputing/Task1`
- 메트릭 이름: `skills-book-5xx-count`
- 메트릭 값: `1`

> ⚠️ 패턴에 `?`(물음표)는 CloudWatch가 거부합니다. Gin 로그의 `| 4xx` 형태를 잡는 `"| 4"` / `"| 5"` 사용.

### 8-3. 알람 2개
CloudWatch → 경보 → **경보 생성** → 지표 선택 → `Skills/CloudComputing/Task1`

**4xx 알람**
- 지표: `skills-book-4xx-count`, 통계 **합계(Sum)**, 기간 **60초**
- 조건: **≥ 1** (임계값 유형 정적, GreaterThanOrEqualToThreshold)
- 추가 구성: 경보 조건 데이터 포인트 **1/1**
- 누락 데이터 처리: **정상(NotBreaching)** 로 처리
- 이름: `skills-book-4xx-alarm`

**5xx 알람**
- 지표 `skills-book-5xx-count`, 나머지 동일
- 이름: `skills-book-5xx-alarm`

> 채점 6-3/6-4: Sum / Threshold 1 / Period 60 / Eval 1 / Datapoints 1 / notBreaching.

---

## 9. ALB

### 9-1. 대상 그룹
EC2 → 대상 그룹 → **대상 그룹 생성**
- 대상 유형: **IP 주소**
- 이름: `skills-book-tg`
- 프로토콜/포트: **HTTP / 8080**
- VPC: `skills-book-vpc`
- 상태 검사 경로: `/health`
- **대상은 등록하지 않음** (ECS Service가 자동 등록)

### 9-2. ALB 생성
EC2 → 로드밸런서 → **Application Load Balancer 생성**
- 이름: `skills-book-alb`
- 체계: **Internet-facing(인터넷 경계)**
- 네트워크: `skills-book-vpc`, 서브넷 **public-1, public-2**
- 보안 그룹: `skills-book-sg`
- 리스너: **HTTP 80**
  - 기본 작업: 일단 `skills-book-tg`로 전달(아래 9-3에서 규칙 수정)

### 9-3. 리스너 규칙 (헤더 기반 차단)
ALB → 리스너 HTTP:80 → **규칙 관리**

**기본 규칙(Default)** 수정:
- 작업: **고정 응답 반환** → HTTP **403**, 본문 `Forbidden`

**규칙 추가 (우선순위 1)**:
- 조건: **HTTP 헤더** → 헤더 이름 `X-Origin-Verify`, 값 `<임의의 20자 이상 비밀값>`
  (예: `SkillsKorea2026SecureHeaderValue!!`)
- 작업: **전달** → `skills-book-tg`

> 채점 3-3: ALB 직접 접근(헤더 없음)은 403, CloudFront가 붙인 헤더 포함 요청은 200.
> 이 `X-Origin-Verify` 값은 **11-3 CloudFront Custom Header 값과 반드시 동일**해야 합니다.

---

## 10. ECS Fargate

### 10-1. 클러스터
ECS → 클러스터 → **클러스터 생성**
- 이름: `skills-book-cluster`
- 인프라: **AWS Fargate(서버리스)**
- 생성 후 → 태그에 Name=`skills-book-cluster` 확인/추가

### 10-2. Task Definition
ECS → 태스크 정의 → **새 태스크 정의 생성**
- 패밀리: `skills-book-task`
- 시작 유형: **AWS Fargate**
- 운영체제: Linux/X86_64
- CPU: **0.25 vCPU(256)**, 메모리: **0.5GB(512)**
- 태스크 역할: `skills-book-ecs-task-role`
- 태스크 실행 역할: `skills-book-ecs-execution-role`
- 컨테이너:
  - 이름: `skills-book-container`
  - 이미지 URI: `<ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/skills-book-app:latest`
  - 포트 매핑: **8080 / TCP**
  - 환경 변수:
    | Key | Value |
    |---|---|
    | AWS_REGION | ap-northeast-2 |
    | TABLE_NAME | skills-book-booking |
  - 로깅: **awslogs 사용** →
    - awslogs-group: `/ecs/skills-book-app`
    - awslogs-region: `ap-northeast-2`
    - awslogs-stream-prefix: `book`

> ⚠️ 콘솔이 자동으로 로그 그룹을 새로 만들려 할 수 있음 → 그룹명이 `/ecs/skills-book-app`인지 확인.

### 10-3. Service
ECS → 클러스터 `skills-book-cluster` → **서비스 생성**
- 시작 유형: **Fargate**
- 태스크 정의: `skills-book-task`(최신 개정)
- 서비스 이름: `skills-book-service`
- 원하는 태스크 수: **2**
- 네트워킹:
  - VPC: `skills-book-vpc`
  - 서브넷: **private-1, private-2**
  - 보안 그룹: `skills-book-sg`
  - **퍼블릭 IP: 끄기(DISABLED)**
- 로드 밸런싱:
  - 유형: **Application Load Balancer**, 기존 `skills-book-alb`
  - 대상 그룹: `skills-book-tg`
  - 컨테이너: `skills-book-container:8080`
- 생성 후 → 서비스 태그 Name=`skills-book-service` 확인/추가

> ⏳ 태스크 2개가 RUNNING + Target Group healthy 되기까지 2~3분.
> Private 서브넷 + NAT/Endpoint 덕분에 ECR pull & 로그 전송 가능.

---

## 11. CloudFront

### 11-1. OAC 생성
CloudFront → 원본 액세스(Origin access) → **컨트롤 설정 생성**
- 이름: `skills-book-oac`
- 서명: **SigV4 / 항상(always)**

### 11-2. 배포 생성 — Origin 1 (S3)
CloudFront → **배포 생성**
- 원본 도메인: `skills-book-static-2026-<비번호>.s3.ap-northeast-2.amazonaws.com`
- 원본 액세스: **Origin access control** → `skills-book-oac`
- 원본 ID: `s3` (기억해둘 것)

### 11-3. Origin 2 (ALB) 추가
배포 생성 화면에서 **원본 추가**:
- 원본 도메인: `skills-book-alb-xxxx.ap-northeast-2.elb.amazonaws.com` (ALB DNS)
- 프로토콜: **HTTP only**, 포트 80
- 원본 ID: `alb`
- **사용자 지정 헤더 추가**:
  - 이름: `X-Origin-Verify`
  - 값: `SkillsKorea2026SecureHeaderValue!!` (9-3의 값과 **동일**, 20자 이상)

### 11-4. 캐시 동작
**기본 캐시 동작(Default)**:
- 대상 원본: `s3`
- 뷰어 프로토콜 정책: **redirect-to-https**
- 허용 메서드: GET, HEAD

**동작 추가(Ordered) — /v1/***:
- 경로 패턴: `/v1/*`
- 대상 원본: `alb`
- 뷰어 프로토콜: redirect-to-https
- 허용 메서드: **GET,HEAD,OPTIONS,PUT,POST,PATCH,DELETE** (POST 필수)
- 캐시 정책: **CachingDisabled** (또는 TTL 0)
- 원본 요청 정책: **AllViewer** (헤더/쿠키/쿼리 전달)

### 11-5. 기타
- 기본 루트 객체: `index.html`
- 배포 태그: Name=`skills-book-cloudfront`
- 생성

### 11-6. S3 버킷 정책 (OAC 허용)
배포 생성 후 Distribution ARN 확인 → S3 버킷 `skills-book-static-2026-<비번호>` → 권한 → 버킷 정책:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontOAC",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::skills-book-static-2026-<비번호>/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>" } }
  }]
}
```

> ⏳ CloudFront 배포 반영까지 **3~5분** 대기.

---

## 12. 검증

CloudShell(또는 로컬 AWS CLI)에서:

```bash
CF=<CloudFront 도메인>   # dxxxx.cloudfront.net
ALB=<ALB DNS>

# 1. 정적페이지 (200)
curl -I https://$CF/index.html

# 2. ALB 직접 접근 차단 (403)
curl -s -o /dev/null -w "%{http_code}\n" http://$ALB/health

# 3. CloudFront 헤더 포함 → 200
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "X-Origin-Verify: SkillsKorea2026SecureHeaderValue!!" http://$ALB/health

# 4. Book API (booking_id 반환)
curl -s -X POST https://$CF/v1/book -H "Content-Type: application/json" \
  -d '{"client_id":"test","username":"tester","email":"t@t.com","concert_name":"skills"}'

# 5. DynamoDB 저장 확인
aws dynamodb scan --region ap-northeast-2 --table-name skills-book-booking --limit 5
```

---

## 부록 A — 리소스 이름 총정리 (채점 대상)

| 리소스 | 이름 |
|---|---|
| VPC | skills-book-vpc |
| Public Subnet | skills-book-public-1/2 |
| Private Subnet | skills-book-private-1/2 |
| IGW | skills-book-igw |
| NAT | skills-book-nat |
| DynamoDB Endpoint | Gateway, dynamodb, private-rt 연결 |
| S3 | skills-book-static-2026-{비번호} |
| CloudFront | skills-book-cloudfront (Name Tag) |
| ECR | skills-book-app (Name Tag = skills-book-ecr) |
| ECS Cluster | skills-book-cluster |
| ECS Service | skills-book-service |
| Task Def | skills-book-task |
| Container | skills-book-container |
| DynamoDB | skills-book-booking (PK booking_id, S) |
| KMS | alias/skills-book-ddb |
| Log Group | /ecs/skills-book-app |
| Metric Filter | skills-book-4xx-filter / 5xx-filter |
| Namespace | Skills/CloudComputing/Task1 |
| Metric | skills-book-4xx-count / 5xx-count |
| Alarm | skills-book-4xx-alarm / 5xx-alarm |
| Execution Role | skills-book-ecs-execution-role |
| Task Role | skills-book-ecs-task-role |

## 부록 B — 자주 틀리는 포인트

- **순서**: 로그 그룹·ECR 이미지가 ECS Service보다 먼저 있어야 태스크가 정상 기동.
- **X-Origin-Verify 값**: ALB 리스너 규칙(9-3)과 CloudFront Custom Header(11-3)가 **글자까지 동일**, 20자 이상.
- **ALB Target Group**: 대상유형 **IP**, 포트 **8080**, 상태검사 `/health`. (instance 아님)
- **ECS 서비스**: private 서브넷 + **퍼블릭 IP 끄기** + Desired **2**.
- **메트릭 필터 패턴**: `?` 금지 → `"| 4"`, `"| 5"` 사용.
- **Execution Role ≠ Task Role**: 반드시 2개 분리 생성.
- **CloudFront /v1/***: POST 허용 + 캐시 비활성 + AllViewer 원본요청정책.
- **S3 버킷 정책**: OAC용 Distribution ARN 조건. Public Access는 4개 모두 차단 유지.
- **최종 제출 URL**: 반드시 **CloudFront 도메인** (S3/ALB URL 제출 시 0점).
