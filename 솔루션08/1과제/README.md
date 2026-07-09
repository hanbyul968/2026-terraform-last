# 1과제 — AWS 콘솔 수행 가이드 (처음부터 끝까지)

Terraform 없이 **AWS 웹 콘솔**만으로 1과제를 완성하는 순서입니다.
위에서부터 순서대로 따라 하면 의존성이 꼬이지 않습니다.

> - 리전은 항상 **아시아 태평양(서울) ap-northeast-2** 로 고정. (콘솔 우측 상단에서 선택)
> - 아래 모든 `<선수ID>` 는 **본인 비번호**로 치환. (예: 비번호가 `07` 이면 `07-vpc`)
> - 리소스 이름/태그는 **대소문자를 구분**하므로 문제지 표기 그대로 입력.
> - 도커 이미지 빌드(6단계)만 콘솔로 불가능 → **CloudShell**(콘솔 우측 상단 `>_` 아이콘) 사용.

---

## 진행 순서 한눈에 보기

| 순서 | 항목 | 콘솔 서비스 | 채점 |
|------|------|-------------|------|
| 1 | VPC / Subnet / IGW / Route Table | VPC | 1-1, 1-2, 1-3 |
| 2 | 보안 그룹 2개 | VPC → 보안 그룹 | 5-3 |
| 3 | DynamoDB 테이블 | DynamoDB | 6-1 |
| 4 | S3 버킷 + 파일 업로드 | S3 | 2-1, 2-2 |
| 5 | IAM Role 2개 | IAM | 4-4 |
| 6 | ECR 저장소 + 이미지 push | ECR + CloudShell | 3-1, 3-2 |
| 7 | CloudWatch 로그 그룹 | CloudWatch | 7-1 |
| 8 | ALB + Target Group | EC2 → 로드밸런서 | 5-1, 5-2 |
| 9 | ECS Cluster / Task / Service | ECS | 4-1~4-5, 7-2, 7-3 |
| 10 | CloudFront + S3 버킷 정책 | CloudFront | 2-2, 2-3 |
| 11 | 동작 확인 | CloudShell | 8-1 |

---

## 1. VPC / 네트워크

### 1-1. VPC 생성
1. **VPC** 콘솔 → 좌측 **VPC** → **VPC 생성**
2. 아래 값으로 설정 (**"VPC 등 여러 개" 아님, "VPC만" 선택**)
   - 생성할 리소스: **VPC만**
   - 이름 태그: `<선수ID>-vpc`
   - IPv4 CIDR: `10.0.0.0/16`
   - 나머지 기본값 → **VPC 생성**
3. 생성 후 **작업 → VPC 설정 편집** 에서 **DNS 호스트 이름 활성화** 체크 (권장)

### 1-2. Public Subnet 2개 생성
1. 좌측 **서브넷** → **서브넷 생성**
2. VPC 선택: `<선수ID>-vpc`
3. **서브넷 1**
   - 이름: `<선수ID>-public-subnet-1`
   - 가용 영역: **ap-northeast-2a**
   - CIDR: `10.0.1.0/24`
4. **새 서브넷 추가** → **서브넷 2**
   - 이름: `<선수ID>-public-subnet-2`
   - 가용 영역: **ap-northeast-2c**
   - CIDR: `10.0.2.0/24`
5. **서브넷 생성**
6. 두 서브넷 각각 선택 → **작업 → 서브넷 설정 편집** → **퍼블릭 IPv4 주소 자동 할당 활성화** 체크

### 1-3. Internet Gateway 생성 & 연결
1. 좌측 **인터넷 게이트웨이** → **인터넷 게이트웨이 생성**
   - 이름: `<선수ID>-igw` → **생성**
2. 생성된 IGW 선택 → **작업 → VPC에 연결** → `<선수ID>-vpc` 선택 → **연결**

### 1-4. 라우팅 테이블 생성 & 연결
1. 좌측 **라우팅 테이블** → **라우팅 테이블 생성**
   - 이름: `<선수ID>-public-rt`
   - VPC: `<선수ID>-vpc` → **생성**
2. 생성된 RT 선택 → **라우팅** 탭 → **라우팅 편집** → **라우팅 추가**
   - 대상: `0.0.0.0/0`
   - 대상(Target): **인터넷 게이트웨이** → `<선수ID>-igw` → **변경 사항 저장**
3. **서브넷 연결** 탭 → **서브넷 연결 편집** → `public-subnet-1`, `public-subnet-2` 둘 다 체크 → **연결 저장**

✅ 채점 1-1(VPC/Subnet), 1-2(IGW/라우팅), 1-3(명명) 완료

---

## 2. 보안 그룹 2개

### 2-1. ALB 보안 그룹
1. **VPC** 콘솔 → 좌측 **보안 그룹** → **보안 그룹 생성**
   - 이름: `<선수ID>-alb-sg`
   - 설명: `ALB SG`
   - VPC: `<선수ID>-vpc`
2. **인바운드 규칙** → **규칙 추가**
   - 유형: **HTTP**, 포트 **80**, 소스: **Anywhere-IPv4 (0.0.0.0/0)**
3. 아웃바운드: 기본(All) 유지 → **보안 그룹 생성**

### 2-2. ECS 보안 그룹
1. **보안 그룹 생성**
   - 이름: `<선수ID>-ecs-sg`
   - 설명: `ECS SG`
   - VPC: `<선수ID>-vpc`
2. **인바운드 규칙** → **규칙 추가**
   - 유형: **사용자 지정 TCP**, 포트 **8080**
   - 소스: **사용자 지정** → 검색창에서 `<선수ID>-alb-sg` (ALB 보안그룹 **ID**) 선택
   - ⚠️ 소스를 반드시 **ALB SG ID**로 지정 (0.0.0.0/0 금지 — 채점 5-3)
3. 아웃바운드: 기본(All, 0.0.0.0/0) 유지 → **보안 그룹 생성**

✅ 채점 5-3(보안그룹 규칙) 완료

---

## 3. DynamoDB 테이블

1. **DynamoDB** 콘솔 → **테이블 생성**
   - 테이블 이름: `<선수ID>-booking-table`
   - 파티션 키: `client_id` / 타입 **문자열(String)**
   - 정렬 키: 없음
   - 테이블 설정: **설정 사용자 지정**
   - 용량 모드: **온디맨드(On-demand)**
2. **테이블 생성**

> 나머지 속성(booking_id, username, email, concert_name, created_at)은 애플리케이션이 저장 시 자동 생성되므로 스키마에 미리 정의하지 않습니다.

✅ 채점 6-1(테이블/PK/빌링모드) 완료

---

## 4. S3 정적 웹 호스팅

### 4-1. 버킷 생성
1. **S3** 콘솔 → **버킷 만들기**
   - 버킷 이름: `<선수ID>-static-site`
   - 리전: **아시아 태평양(서울) ap-northeast-2**
   - **모든 퍼블릭 액세스 차단**: **체크 유지(켜짐)** ← 채점 2-2
   - 나머지 기본값 → **버킷 만들기**

### 4-2. 파일 업로드
1. 생성한 버킷 클릭 → **업로드** → **파일 추가**
2. 지급받은 `index.html`, `main.jpeg` 선택 → **업로드**

> CloudFront에서 접근할 수 있게 하는 **버킷 정책**은 CloudFront를 만든 뒤 **10단계**에서 추가합니다. (CloudFront ARN이 필요하기 때문)

✅ 채점 2-1(파일 업로드), 2-2(퍼블릭 차단) 완료 — OAC는 10단계에서

---

## 5. IAM Role 2개

### 5-1. Task Execution Role (ECR pull + 로그 전송)
1. **IAM** 콘솔 → **역할** → **역할 생성**
   - 신뢰할 수 있는 엔터티: **AWS 서비스**
   - 사용 사례: **Elastic Container Service** → **Elastic Container Service Task** 선택
2. **다음** → 권한 정책에서 `AmazonECSTaskExecutionRolePolicy` 검색·체크
3. **다음** → 역할 이름: `<선수ID>-ecs-task-execution-role` → **역할 생성**

### 5-2. Task Role (DynamoDB 저장 권한)
1. **역할 생성** → **AWS 서비스** → **Elastic Container Service Task**
2. **다음** → 우선 권한 없이 진행 → 역할 이름: `<선수ID>-ecs-task-role` → **역할 생성**
3. 생성된 `<선수ID>-ecs-task-role` 클릭 → **권한 추가 → 인라인 정책 생성**
4. **JSON** 탭에 아래 붙여넣기 (`<선수ID>`, `<계정ID>` 치환)
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "BookingTableAccess",
         "Effect": "Allow",
         "Action": [
           "dynamodb:PutItem",
           "dynamodb:GetItem",
           "dynamodb:UpdateItem",
           "dynamodb:Query",
           "dynamodb:DescribeTable"
         ],
         "Resource": "arn:aws:dynamodb:ap-northeast-2:<계정ID>:table/<선수ID>-booking-table"
       }
     ]
   }
   ```
5. 정책 이름: `<선수ID>-dynamodb-access` → **정책 생성**

✅ 채점 4-4(IAM Role) 완료

---

## 6. ECR 저장소 + 이미지 빌드/푸시

### 6-1. 저장소 생성 (콘솔)
1. **ECR** 콘솔 → **리포지토리 생성**
   - 표시 여부: **프라이빗**
   - 리포지토리 이름: `<선수ID>-book-ecr`
   - **리포지토리 생성**

### 6-2. 이미지 빌드 & 푸시 (CloudShell)
> 도커 빌드는 콘솔로 불가 → 콘솔 우측 상단 **CloudShell(`>_`)** 실행 후 진행.

```bash
PID=<선수ID>
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$PID-book-ecr

# 작업 폴더에 지급 파일(book) + Dockerfile 준비
mkdir -p ~/app && cd ~/app
# book 파일 업로드: CloudShell 우측 상단 [작업] → [파일 업로드] 로 book 올린 뒤 ~/app 로 이동
#   mv ~/book ~/app/book   (업로드 위치가 홈이면)

cat > Dockerfile <<'EOF'
FROM --platform=linux/amd64 amazonlinux:2023
COPY book /app/book
RUN chmod +x /app/book
EXPOSE 8080
CMD ["/app/book"]
EOF

# ECR 로그인
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com

# 빌드(AMD64) → 태그 latest → 푸시
docker build --platform linux/amd64 -t $REPO:latest .
docker push $REPO:latest
```

> CloudShell에 buildx가 없어도 위 `docker build --platform linux/amd64` 로 AMD64 이미지가 만들어집니다.
> 이미지 URI(`$REPO:latest`)는 9단계 Task Definition에서 사용합니다.

✅ 채점 3-1(저장소), 3-2(latest/AMD64) 완료

---

## 7. CloudWatch 로그 그룹

1. **CloudWatch** 콘솔 → **로그 → 로그 그룹** → **로그 그룹 생성**
   - 로그 그룹 이름: `/skillskorea/ecs/app`  ← **정확히 이 이름 (고정)**
   - 보존 기간: 임의(예: 2주)
2. **생성**

✅ 채점 7-1(로그 그룹) 완료

---

## 8. ALB (Application Load Balancer)

### 8-1. 대상 그룹(Target Group) 먼저 생성
1. **EC2** 콘솔 → 좌측 **대상 그룹** → **대상 그룹 생성**
   - 대상 유형: **IP 주소** ← 중요
   - 이름: `<선수ID>-book-tg`
   - 프로토콜/포트: **HTTP : 8080**
   - VPC: `<선수ID>-vpc`
   - 상태 검사 경로: `/health`, 정상 코드: `200` (고급 → 성공 코드 200)
2. **다음** → 대상 등록은 **비워두고**(ECS가 자동 등록) → **대상 그룹 생성**

### 8-2. ALB 생성
1. 좌측 **로드 밸런서** → **로드 밸런서 생성** → **Application Load Balancer**
   - 이름: `<선수ID>-book-alb`
   - 체계(Scheme): **인터넷 경계(Internet-facing)**
   - IP 주소 유형: IPv4
   - VPC: `<선수ID>-vpc`
   - 매핑: **ap-northeast-2a → public-subnet-1**, **ap-northeast-2c → public-subnet-2** 둘 다 체크
   - 보안 그룹: `<선수ID>-alb-sg` (기본 SG는 제거)
2. **리스너 및 라우팅**
   - 프로토콜 **HTTP**, 포트 **80** → 기본 작업: **전달 대상** `<선수ID>-book-tg`
3. **로드 밸런서 생성**

✅ 채점 5-1(ALB), 5-2(리스너/TG) — Target Health는 ECS 배포 후 Healthy가 됨

---

## 9. ECS (Fargate)

### 9-1. 클러스터
1. **ECS** 콘솔 → **클러스터** → **클러스터 생성**
   - 클러스터 이름: `<선수ID>-book-cluster`
   - 인프라: **AWS Fargate(서버리스)** 체크
2. **생성**

### 9-2. 태스크 정의(Task Definition)
1. 좌측 **태스크 정의** → **새 태스크 정의 생성**
   - 태스크 정의 패밀리: `<선수ID>-book-task`
   - 시작 유형: **AWS Fargate**
   - 운영체제/아키텍처: **Linux/X86_64**
   - CPU: **0.25 vCPU (256)** / 메모리: **0.5 GB (512)**  ← 값 고정
   - 태스크 실행 역할: `<선수ID>-ecs-task-execution-role`
   - 태스크 역할: `<선수ID>-ecs-task-role`
2. **컨테이너 - 1**
   - 이름: `book`
   - 이미지 URI: `<계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com/<선수ID>-book-ecr:latest`
   - 포트 매핑: 컨테이너 포트 **8080**, 프로토콜 **TCP**
   - 환경 변수:
     - `AWS_REGION` = `ap-northeast-2`
     - `TABLE_NAME` = `<선수ID>-booking-table`
   - **로깅** 섹션: **awslogs 사용** 체크 후, 자동 생성 대신 아래로 지정
     - awslogs-group: `/skillskorea/ecs/app`
     - awslogs-region: `ap-northeast-2`
     - awslogs-stream-prefix: `ecs`
3. **생성**

> 콘솔이 로그 그룹을 자동으로 다른 이름으로 만들려 하면, 로그 옵션에서 그룹 이름을 `/skillskorea/ecs/app` 로 직접 수정하세요. (채점 7-3)

### 9-3. 서비스(Service)
1. `<선수ID>-book-cluster` → **서비스** 탭 → **생성**
   - 시작 유형: **FARGATE**
   - 태스크 정의: `<선수ID>-book-task` (최신 개정)
   - 서비스 이름: `<선수ID>-book-service`
   - 원하는 태스크 수: **1**
2. **네트워킹**
   - VPC: `<선수ID>-vpc`
   - 서브넷: `public-subnet-1`, `public-subnet-2` 둘 다
   - 보안 그룹: **기존 선택** `<선수ID>-ecs-sg`
   - 퍼블릭 IP: **켜기(ENABLED)**
3. **로드 밸런싱**
   - 로드 밸런서 유형: **Application Load Balancer**
   - 기존 로드 밸런서: `<선수ID>-book-alb`
   - 컨테이너: `book 8080:8080`
   - 대상 그룹: **기존 선택** `<선수ID>-book-tg`
4. **생성**

> 1~3분 후 태스크가 **Running**, 대상 그룹에서 대상이 **Healthy** 가 되는지 확인.
> Healthy가 안 되면: ECS SG 인바운드 8080(소스 ALB SG), TG 헬스체크 경로 `/health` 확인.

✅ 채점 4-1~4-5, 7-2, 7-3 완료

---

## 10. CloudFront + S3 버킷 정책

### 10-1. 배포(Distribution) 생성
1. **CloudFront** 콘솔 → **배포 생성**
2. **오리진 1 (S3)**
   - 오리진 도메인: `<선수ID>-static-site.s3.ap-northeast-2.amazonaws.com` 선택
   - 오리진 액세스: **Origin access control settings (권장)** 선택
     - **제어 설정 생성** → 이름 `<선수ID>-s3-oac` → 생성
   - (콘솔이 "버킷 정책을 업데이트하라"는 안내 배너를 표시함 → 나중에 복사)
3. **기본 캐시 동작**
   - 뷰어 프로토콜 정책: **Redirect HTTP to HTTPS**
   - 허용 HTTP 메서드: **GET, HEAD, OPTIONS**
   - 캐시 정책: **CachingOptimized**
4. **설정**
   - 기본값 루트 객체: `index.html`
   - **배포 생성**

### 10-2. ALB 오리진 추가
1. 생성된 배포 → **오리진** 탭 → **오리진 생성**
   - 오리진 도메인: `<선수ID>-book-alb-xxxx.ap-northeast-2.elb.amazonaws.com` (ALB DNS)
   - 프로토콜: **HTTP만(HTTP only)**, HTTP 포트 **80**
   - **오리진 생성**

### 10-3. 동작(Behavior) 추가 — API를 ALB로 라우팅
1. **동작** 탭 → **동작 생성**
   - 경로 패턴: `/v1/*`
   - 오리진: **ALB 오리진**
   - 뷰어 프로토콜: **Redirect HTTP to HTTPS**
   - 허용 메서드: **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE**
   - 캐시 정책: **CachingDisabled**
   - 오리진 요청 정책: **AllViewer**
   - **동작 생성**
2. 다시 **동작 생성**
   - 경로 패턴: `/health`
   - 오리진: **ALB 오리진**
   - 허용 메서드: **GET, HEAD, OPTIONS**
   - 캐시 정책: **CachingDisabled** / 오리진 요청 정책: **AllViewer**
   - **동작 생성**

### 10-4. S3 버킷 정책 붙이기 (OAC 접근 허용)
1. CloudFront 배포 상세 상단에 뜬 **정책 복사** 배너 이용, 또는 아래 정책을 직접 사용
2. **S3** → `<선수ID>-static-site` → **권한** 탭 → **버킷 정책 → 편집** → 붙여넣기
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowCloudFrontServicePrincipalReadOnly",
         "Effect": "Allow",
         "Principal": { "Service": "cloudfront.amazonaws.com" },
         "Action": "s3:GetObject",
         "Resource": "arn:aws:s3:::<선수ID>-static-site/*",
         "Condition": {
           "StringEquals": {
             "AWS:SourceArn": "arn:aws:cloudfront::<계정ID>:distribution/<Distribution-ID>"
           }
         }
       }
     ]
   }
   ```
3. **변경 사항 저장**

> `<Distribution-ID>` 는 CloudFront 배포 목록의 ID (예: `E123ABC...`).
> 배포 상태가 **Deployed** 가 될 때까지 최대 3분 대기.

✅ 채점 2-2(OAC), 2-3(URL 200/index.html) 완료

---

## 11. 최종 동작 확인 (CloudShell)

```bash
PID=<선수ID>
CF=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'${PID}-static-site')]].DomainName|[0]" \
  --output text)
echo "https://$CF/"

# 1) 정적 페이지 (200)
curl -s -o /dev/null -w "ROOT:%{http_code}\n" "https://$CF/"

# 2) 헬스체크 (200, {"status":"OK","version":"1.0.1"})
curl -s "https://$CF/health"; echo

# 3) 예약 생성 → booking_id 응답
curl -s -X POST "https://$CF/v1/book" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"C001","username":"Alice","email":"kim@example.com","concert_name":"Seoul2026"}'; echo

# 4) DynamoDB 저장 확인
aws dynamodb get-item --table-name $PID-booking-table \
  --key '{"client_id":{"S":"C001"}}' --output json
```

- ROOT: 200 / health: 200 & OK / book: `{"booking_id":"..."}` / DynamoDB에 6개 속성 저장 → **완료**

✅ 채점 8-1(종합 동작) 완료

---

## 12. 체크리스트 (제출 전 최종 점검)

- [ ] VPC `10.0.0.0/16`, 서브넷 2개(2a/2c), IGW 연결, 라우팅 0.0.0.0/0→IGW
- [ ] 모든 리소스 이름에 `<선수ID>` 접두어
- [ ] S3 퍼블릭 차단 ON, index.html·main.jpeg 업로드, OAC 버킷정책
- [ ] CloudFront: Deployed, 기본 루트 index.html, `/v1/*`·`/health`→ALB
- [ ] ECR `latest` 이미지, AMD64
- [ ] ECS: Task Running, CPU256/MEM512/포트8080, 환경변수 2개, awslogs `/skillskorea/ecs/app`
- [ ] ALB internet-facing, 리스너 HTTP:80, TG HTTP:8080/IP, 대상 Healthy
- [ ] ECS SG 인바운드 8080 소스 = ALB SG ID
- [ ] DynamoDB PK `client_id`, 온디맨드
- [ ] **불필요 리소스 없음** (미사용 EC2/ALB/VPC 등 → 채점 8-2)
- [ ] IAM AccessKey 미구성(있으면 삭제)

> ⚠️ **채점 8-2**: 문제 요구 외 EC2/로드밸런서/VPC가 있으면 감점·0점. 작업 중 만든 임시 리소스는 반드시 삭제하세요.
