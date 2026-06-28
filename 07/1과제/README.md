# 2026 전국기능경기대회 07 - 1과제

## 실행법 (Windows PowerShell)

### Step 1. Terraform 설치

[terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) 에서 Windows AMD64 zip 다운로드 후 `terraform.exe`를 PATH에 추가.

또는 winget:
```powershell
winget install HashiCorp.Terraform
```

### Step 2. AWS 자격증명 설정

```powershell
aws configure
# AWS Access Key ID, Secret, region: ap-northeast-2, output: json
```

### Step 3. 리포 클론

```powershell
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/07/1과제
```

### Step 4. 지급 바이너리 배치

지급받은 `book` 바이너리를 `app\book` 으로 복사:

```powershell
Copy-Item C:\path\to\book app\book
```

### Step 5. 배포

```powershell
terraform init
terraform apply -var="bibunho=비번호" -auto-approve
```

**동작 흐름:**
1. VPC / 서브넷 / IGW / NAT / DynamoDB Endpoint 생성
2. Bastion EC2 자동 생성 → SSH로 docker 빌드/푸시 → ECR에 이미지 업로드
3. ECS Fargate 서비스 기동 (bastion 완료 후)
4. CloudFront 배포 반영까지 **3~5분** 소요

> `bastion-key.pem` 파일이 현재 디렉터리에 자동 생성됩니다 (SSH 접속 필요 시 사용).

### Step 5-1. IAM Role 충돌 시 (EntityAlreadyExists 에러)

이전 apply 잔재로 IAM Role이 남아 있을 때 발생. import 후 재apply:

```powershell
terraform import aws_iam_role.ecs_execution skills-book-ecs-execution-role
terraform import aws_iam_role.ecs_task skills-book-ecs-task-role
terraform apply -var="bibunho=비번호" -auto-approve
```

## 검증

```bash
# CloudFront 정적페이지
curl -I https://$(terraform output -raw cloudfront_domain)/index.html

# ALB 직접 접근 차단 (403)
curl -s -o /dev/null -w "%{http_code}" http://$(terraform output -raw alb_dns)/health

# Book API
curl -X POST https://$(terraform output -raw cloudfront_domain)/v1/book \
  -H "Content-Type: application/json" \
  -d '{"client_id":"test","username":"tester","email":"t@t.com","concert_name":"skills"}'
```

## 구조

```
├── provider.tf          # AWS Provider
├── variables.tf         # bibunho, origin_verify_value
├── outputs.tf           # CloudFront domain, ALB DNS
├── vpc.tf               # VPC, Subnet, IGW, NAT, DynamoDB VPC Endpoint
├── sg.tf                # Security Group
├── alb.tf               # ALB, TG, Listener (default 403 + header forward)
├── s3_cloudfront.tf     # S3 + CloudFront OAC + /v1/* -> ALB
├── iam.tf               # Execution Role, Task Role (DynamoDB+KMS)
├── ecs.tf               # ECR + Docker build/push + ECS Cluster/Service
├── dynamodb.tf          # DynamoDB + KMS CMK
├── cloudwatch.tf        # Log Group, Metric Filters, Alarms
└── app/
    ├── Dockerfile
    ├── book             # 지급 바이너리
    ├── index.html
    └── main.jpeg
```

## 주요 리소스명

| 리소스 | 이름 |
|--------|------|
| VPC | skills-book-vpc |
| S3 | skills-book-static-2026-{비번호} |
| CloudFront | skills-book-cloudfront |
| ECR | skills-book-ecr (Name Tag) |
| ECS Cluster | skills-book-cluster |
| ECS Service | skills-book-service |
| Task Def | skills-book-task |
| Container | skills-book-container |
| DynamoDB | skills-book-booking |
| KMS | alias/skills-book-ddb |
| Log Group | /ecs/skills-book-app |
| Alarms | skills-book-4xx-alarm, skills-book-5xx-alarm |
| Execution Role | skills-book-ecs-execution-role |
| Task Role | skills-book-ecs-task-role |

---

## 대회 당일 변경 가이드 (최대 30% 수정 대응)

과제지가 수정될 경우 아래 표를 참고해 해당 파일의 해당 위치만 수정하세요.

### VPC / 네트워크

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| VPC CIDR 변경 | `vpc.tf` | `aws_vpc.main` 블록의 `cidr_block = "10.0.0.0/16"` |
| Public Subnet CIDR 변경 | `vpc.tf` | `aws_subnet.public` 의 `cidr_block = cidrsubnet(...)` 수식 (8, count.index 부분) |
| Private Subnet CIDR 변경 | `vpc.tf` | `aws_subnet.private` 의 `cidr_block = cidrsubnet(...)` 수식 (8, count.index + 10 부분) |
| Subnet 개수 변경 (2→N) | `vpc.tf` | `aws_subnet.public` 과 `aws_subnet.private` 의 `count = 2` |
| VPC Name Tag 변경 | `vpc.tf` | `aws_vpc.main` 의 `tags = { Name = "skills-book-vpc" }` |
| DynamoDB VPC Endpoint 제거 | `vpc.tf` | `aws_vpc_endpoint.dynamodb` 블록 전체 삭제 |

### S3 / CloudFront

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| S3 버킷 이름 변경 | `s3_cloudfront.tf` | `aws_s3_bucket.static` 의 `bucket = "skills-book-static-2026-${var.bibunho}"` |
| CloudFront 기본 루트 객체 변경 | `s3_cloudfront.tf` | `aws_cloudfront_distribution.main` 의 `default_root_object = "index.html"` |
| ALB Origin 경로 패턴 변경 (`/v1/*` → 다른 경로) | `s3_cloudfront.tf` | `ordered_cache_behavior` 블록의 `path_pattern = "/v1/*"` |
| CloudFront Custom Header 이름 변경 (`X-Origin-Verify`) | `s3_cloudfront.tf` + `alb.tf` | `custom_header { name = ... }` (s3_cloudfront.tf) 와 `http_header_name = ...` (alb.tf) 동시 변경 |
| CloudFront Custom Header 값 변경 | `variables.tf` | `origin_verify_value` default 값 (또는 apply 시 `-var="origin_verify_value=..."`) |
| S3에 업로드할 정적 파일 추가 | `s3_cloudfront.tf` | `aws_s3_object` 블록 추가 (index.html, main.jpeg 참고) |

### ALB

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| ALB Listener 포트 변경 (80 → 다른 포트) | `alb.tf` | `aws_lb_listener.http` 의 `port = 80` |
| Target Group 포트 변경 (8080 → 다른 포트) | `alb.tf` + `ecs.tf` | `aws_lb_target_group.ecs` 의 `port = 8080` 과 ECS container의 `containerPort = 8080` |
| Health Check 경로 변경 (`/health` → 다른 경로) | `alb.tf` | `health_check { path = "/health" }` |
| ALB 이름 변경 | `alb.tf` | `aws_lb.main` 의 `name = "skills-book-alb"` |

### ECR / ECS

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| ECR 리포지토리 이름 변경 | `ecs.tf` | `aws_ecr_repository.book` 의 `name = "skills-book-app"` |
| ECS Cluster 이름 변경 | `ecs.tf` | `aws_ecs_cluster.main` 의 `name = "skills-book-cluster"` 과 `tags` |
| ECS Service 이름 변경 | `ecs.tf` | `aws_ecs_service.book` 의 `name = "skills-book-service"` 과 `tags` |
| Task Definition Family 변경 | `ecs.tf` | `aws_ecs_task_definition.book` 의 `family = "skills-book-task"` |
| Container 이름 변경 | `ecs.tf` | `container_definitions` 내 `name = "skills-book-container"` 과 `aws_ecs_service.book` 의 `container_name = "skills-book-container"` |
| Desired Count 변경 (2 → N) | `ecs.tf` | `aws_ecs_service.book` 의 `desired_count = 2` |
| Container 포트 변경 (8080 → 다른 포트) | `ecs.tf` + `alb.tf` | `portMappings[0].containerPort` 과 `aws_lb_target_group.ecs` 의 `port` |
| Task CPU/Memory 변경 | `ecs.tf` | `aws_ecs_task_definition.book` 의 `cpu = "256"` 과 `memory = "512"` |
| 환경 변수 변경 (AWS_REGION, TABLE_NAME 등) | `ecs.tf` | `container_definitions` 내 `environment` 배열 |
| CloudWatch Log Group 이름 변경 | `ecs.tf` + `cloudwatch.tf` | `awslogs-group` 값 (ecs.tf) 과 `aws_cloudwatch_log_group.ecs` 의 `name` (cloudwatch.tf) |
| Log Stream Prefix 변경 (`book`) | `ecs.tf` | `awslogs-stream-prefix = "book"` |
| Execution Role 이름 변경 | `iam.tf` | `aws_iam_role.ecs_execution` 의 `name` |
| Task Role 이름 변경 | `iam.tf` | `aws_iam_role.ecs_task` 의 `name` |

### DynamoDB / KMS

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| DynamoDB 테이블 이름 변경 | `dynamodb.tf` + `ecs.tf` | `aws_dynamodb_table.booking` 의 `name` 과 ECS `environment` 의 `TABLE_NAME` 값 |
| Partition Key 이름/타입 변경 | `dynamodb.tf` | `hash_key = "booking_id"` 과 `attribute { name = "booking_id" type = "S" }` |
| KMS Key Alias 변경 | `dynamodb.tf` | `aws_kms_alias.dynamodb` 의 `name = "alias/skills-book-ddb"` |

### CloudWatch

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| Log Group 이름 변경 | `cloudwatch.tf` + `ecs.tf` | `aws_cloudwatch_log_group.ecs` 의 `name` 과 ECS `awslogs-group` 값 동시 변경 |
| Metric Filter 이름 변경 | `cloudwatch.tf` | `aws_cloudwatch_log_metric_filter.f4xx/f5xx` 의 `name` |
| Metric Namespace 변경 | `cloudwatch.tf` | `metric_transformation` 의 `namespace` (f4xx, f5xx, 알람 3곳 모두) |
| Metric 이름 변경 (4xx-count 등) | `cloudwatch.tf` | `metric_transformation.name` 과 `aws_cloudwatch_metric_alarm` 의 `metric_name` 동시 변경 |
| Metric Filter 패턴 변경 | `cloudwatch.tf` | `pattern` 값 (`[w1, date, dash, time, pipe, status=4??, ...]`) |
| Alarm 이름 변경 | `cloudwatch.tf` | `aws_cloudwatch_metric_alarm.a4xx/a5xx` 의 `alarm_name` |
| Alarm Threshold 변경 | `cloudwatch.tf` | `threshold = 1` |
| Alarm Period 변경 | `cloudwatch.tf` | `period = 60` |
| Alarm Evaluation Periods 변경 | `cloudwatch.tf` | `evaluation_periods = 1` |

### variables.tf (공통 변수)

| 변경 항목 | 수정 위치 |
|-----------|-----------|
| 비번호 변경 | apply 시 `-var="bibunho=새비번호"` 또는 `default` 값 |
| X-Origin-Verify 헤더 값 변경 | `origin_verify_value` default 값 변경 (20자 이상 유지) |

---

## 자주 바뀌는 값 한눈에 보기

```
비번호          → variables.tf : bibunho
VPC CIDR        → vpc.tf : aws_vpc.main.cidr_block
컨테이너 포트    → ecs.tf : containerPort  +  alb.tf : port (TG)
TABLE_NAME      → ecs.tf : environment TABLE_NAME  +  dynamodb.tf : name
로그 그룹       → cloudwatch.tf : name  +  ecs.tf : awslogs-group
```
