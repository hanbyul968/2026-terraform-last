# 1과제 테라폼 — 배포 가이드 & 대회 당일 수정 지침

## 배포 방법

### 0. Terraform 설치 (CloudShell 최초 1회)

```bash
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform
terraform version   # 설치 확인
```

### 1. 파일 배치

```
1과제/
├── app/
│   ├── Dockerfile   # 아래 예시 참고
│   └── book         # 지급 바이너리
└── static/
    ├── index.html   # 지급 파일
    └── main.jpeg    # 지급 파일
```

**Dockerfile 예시**
```dockerfile
FROM --platform=linux/amd64 amazonlinux:2023
COPY book /app/book
RUN chmod +x /app/book
EXPOSE 8080
CMD ["/app/book"]
```

### 2. 코드 받기 & 이동

```bash
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/08/1과제
```

### 3. 배포

```bash
terraform init
terraform apply -var="player_id=<비번호>" -auto-approve
```

> CloudFront 배포 완료까지 최대 3분 소요.

### 3-1. 409 에러 발생 시 (리소스 이미 존재)

이전 apply 후 state 없이 재시작하면 `EntityAlreadyExists` / `OriginAccessControlAlreadyExists` 에러가 납니다.  
아래 순서로 import 후 다시 apply하세요.

```bash
PID=<비번호>   # 본인 비번호로 변경

# OAC import
OAC_ID=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${PID}-s3-oac'].Id" \
  --output text)
terraform import -var="player_id=${PID}" aws_cloudfront_origin_access_control.s3 $OAC_ID

# IAM Role import
terraform import -var="player_id=${PID}" aws_iam_role.task_execution ${PID}-ecs-task-execution-role
terraform import -var="player_id=${PID}" aws_iam_role.task              ${PID}-ecs-task-role

# 다시 apply
terraform apply -var="player_id=${PID}" -auto-approve
```

> 다른 리소스(VPC, ALB 등)도 같은 에러가 나면 아래 명령으로 리소스 ID를 확인 후 동일하게 import합니다.
>
> | 리소스 | ID 확인 명령 | import 주소 |
> |--------|-------------|-------------|
> | VPC | `aws ec2 describe-vpcs --filters Name=tag:Name,Values=${PID}-vpc --query Vpcs[0].VpcId --output text` | `aws_vpc.main` |
> | Subnet 1 | `aws ec2 describe-subnets --filters Name=tag:Name,Values=${PID}-public-subnet-1 --query Subnets[0].SubnetId --output text` | `aws_subnet.public[0]` |
> | Subnet 2 | `aws ec2 describe-subnets --filters Name=tag:Name,Values=${PID}-public-subnet-2 --query Subnets[0].SubnetId --output text` | `aws_subnet.public[1]` |
> | IGW | `aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=${PID}-igw --query InternetGateways[0].InternetGatewayId --output text` | `aws_internet_gateway.main` |
> | Route Table | `aws ec2 describe-route-tables --filters Name=tag:Name,Values=${PID}-public-rt --query RouteTables[0].RouteTableId --output text` | `aws_route_table.public` |
> | S3 버킷 | 버킷명 그대로 | `aws_s3_bucket.static` |
> | ECR | `aws ecr describe-repositories --repository-names ${PID}-book-ecr --query repositories[0].repositoryArn --output text` | `aws_ecr_repository.book` |
> | ALB | `aws elbv2 describe-load-balancers --names ${PID}-book-alb --query LoadBalancers[0].LoadBalancerArn --output text` | `aws_lb.book` |
> | DynamoDB | 테이블명 그대로 | `aws_dynamodb_table.booking` |
> | ECS Cluster | 클러스터명 그대로 | `aws_ecs_cluster.book` |
> | ALB SG | `aws ec2 describe-security-groups --filters Name=group-name,Values=${PID}-alb-sg --query SecurityGroups[0].GroupId --output text` | `aws_security_group.alb` |
> | ECS SG | `aws ec2 describe-security-groups --filters Name=group-name,Values=${PID}-ecs-sg --query SecurityGroups[0].GroupId --output text` | `aws_security_group.ecs` |

### 4. 동작 확인

```bash
CF=$(terraform output -raw cloudfront_domain_name)

# 정적 페이지 (200 확인)
curl -s -o /dev/null -w "%{http_code}" "https://$CF/"

# 헬스체크 ({"status":"OK","version":"1.0.1"} 확인)
curl -s "https://$CF/health"

# 예약 생성
curl -s -X POST "https://$CF/v1/book" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"C001","username":"Alice","email":"kim@example.com","concert_name":"Seoul2026"}'
```

### 5. 정리

```bash
terraform destroy -var="player_id=<비번호>" -auto-approve
```

---

## 아키텍처

```
사용자 → CloudFront → S3 (정적, OAC)
                    → ALB:80 → ECS Fargate (book:8080) → DynamoDB
                                                        → CloudWatch Logs (/skillskorea/ecs/app)
```

---

## 대회 당일 수정 가이드

과제지가 변경될 경우 아래 표를 기준으로 수정하세요.  
`variables.tf` 하나만 수정하면 해결되는 항목이 대부분입니다.

---

### 선수 ID (비번호)

- **수정 불필요** — `terraform apply -var="player_id=<비번호>"` 로 전달
- 모든 리소스 Name 태그에 자동 반영됨

---

### VPC CIDR 변경 (기본: `10.0.0.0/16`)

**파일:** `variables.tf`

```hcl
variable "vpc_cidr" {
  default = "10.0.0.0/16"   # ← 여기를 새 CIDR로 수정
}
```

---

### Public Subnet CIDR 변경 (기본: `10.0.1.0/24`, `10.0.2.0/24`)

**파일:** `variables.tf`

```hcl
variable "public_subnet_cidrs" {
  default = ["10.0.1.0/24", "10.0.2.0/24"]   # ← 두 값 모두 수정
}
```

---

### 가용영역(AZ) 변경 (기본: `ap-northeast-2a`, `ap-northeast-2c`)

**파일:** `variables.tf`

```hcl
variable "azs" {
  default = ["ap-northeast-2a", "ap-northeast-2c"]   # ← 수정
}
```

---

### AWS 리전 변경 (기본: `ap-northeast-2`)

**파일:** `variables.tf`

```hcl
variable "region" {
  default = "ap-northeast-2"   # ← 수정
}
```

> ECS 환경변수 `AWS_REGION`과 CloudWatch `awslogs-region`은 `var.region`을 참조하므로 자동 반영됨.  
> `versions.tf` 의 provider 블록에 리전이 하드코딩되어 있다면 거기도 수정.

---

### 컨테이너 포트 변경 (기본: `8080`)

**파일:** `variables.tf`

```hcl
variable "container_port" {
  default = 8080   # ← 수정
}
```

> `alb.tf` Target Group 포트, `ecs.tf` portMappings, `security_groups.tf` ECS SG 인바운드 포트가 모두 이 변수를 참조하므로 자동 반영됨.

---

### ECS Task CPU / Memory 변경 (기본: `256` / `512`)

**파일:** `variables.tf`

```hcl
variable "task_cpu" {
  default = "256"   # ← 변경할 CPU Units
}
variable "task_memory" {
  default = "512"   # ← 변경할 MiB
}
```

---

### CloudWatch 로그 그룹 이름 변경 (기본: `/skillskorea/ecs/app`)

> 채점 기준 7-1, 7-3이 이 이름에 의존 — 과제지에서 명시적으로 바뀌는 경우에만 수정.

**파일:** `variables.tf`

```hcl
variable "log_group_name" {
  default = "/skillskorea/ecs/app"   # ← 수정
}
```

---

### CloudFront 라우팅 경로 변경 (`/v1/*`, `/health`)

**파일:** `cloudfront.tf`

```hcl
ordered_cache_behavior {
  path_pattern = "/v1/*"    # ← API 경로가 달라지면 수정
  ...
}
ordered_cache_behavior {
  path_pattern = "/health"  # ← 헬스체크 경로가 달라지면 수정
  ...
}
```

> ALB Target Group 헬스체크 경로도 `alb.tf` 의 `health_check { path = "/health" }` 에서 함께 수정.

---

### ALB 리스너 포트 변경 (기본: HTTP `80`)

| 파일 | 위치 |
|------|------|
| `alb.tf` | `aws_lb_listener.http` 블록의 `port` |
| `security_groups.tf` | `aws_vpc_security_group_ingress_rule.alb_http` 의 `from_port` / `to_port` |
| `cloudfront.tf` | `custom_origin_config { http_port = 80 }` |

---

### DynamoDB 빌링 모드 변경 (기본: `PAY_PER_REQUEST`)

**파일:** `dynamodb.tf`

```hcl
resource "aws_dynamodb_table" "booking" {
  billing_mode = "PAY_PER_REQUEST"   # ← "PROVISIONED" 으로 바꿀 경우
                                     #   read_capacity, write_capacity 속성도 추가
}
```

---

### 정적 파일 경로 변경 (기본: `static/index.html`, `static/main.jpeg`)

**파일:** `s3.tf`

```hcl
resource "aws_s3_object" "index" {
  source = "${path.module}/static/index.html"   # ← 경로 수정
}
resource "aws_s3_object" "main_jpeg" {
  source = "${path.module}/static/main.jpeg"    # ← 경로 수정
}
```

---

### ECR / 도커 빌드 컨텍스트 경로 변경 (기본: `./app`)

**파일:** `ecr.tf`

```hcl
locals {
  dockerfile_hash  = filemd5("${path.module}/app/Dockerfile")   # ← app → 새 경로
  book_binary_hash = filemd5("${path.module}/app/book")         # ← app → 새 경로
}

provisioner "local-exec" {
  command = <<-EOT
    ...
    docker buildx build --platform linux/amd64 -t ${local.image_uri} --push ./app
    #                                                                        ^^^^ 수정
  EOT
}
```

---

### ECS Desired Count 변경 (기본: `1`)

**파일:** `ecs.tf`

```hcl
resource "aws_ecs_service" "book" {
  desired_count = 1   # ← 과제에서 1 이상을 요구; 필요시 늘림
}
```

---

## 채점 항목 ↔ 테라폼 파일 대응표

| 채점 번호 | 항목 | 관련 파일 |
|-----------|------|-----------|
| 1-1 | VPC/Subnet | `network.tf`, `variables.tf` |
| 1-2 | IGW/라우팅 | `network.tf` |
| 1-3 | 리소스 명명 규칙 | `variables.tf` (`player_id`) |
| 2-1 | S3 파일 업로드 | `s3.tf` |
| 2-2 | S3 퍼블릭 차단 + OAC | `s3.tf`, `cloudfront.tf` |
| 2-3 | CloudFront 200 + index.html | `cloudfront.tf` |
| 3-1 | ECR Repository | `ecr.tf` |
| 3-2 | ECR latest 이미지 + AMD64 | `ecr.tf`, `ecs.tf` |
| 4-1 | ECS Cluster ACTIVE + Task Running | `ecs.tf` |
| 4-2 | Task Definition (포트/CPU/MEM/ARCH) | `ecs.tf`, `variables.tf` |
| 4-3 | 환경변수 AWS_REGION, TABLE_NAME | `ecs.tf` |
| 4-4 | IAM Execution Role / Task Role | `iam.tf` |
| 4-5 | /health → 200 | `cloudfront.tf`, `alb.tf`, `ecs.tf` |
| 5-1 | ALB internet-facing | `alb.tf` |
| 5-2 | Listener:80, TG:8080/IP, Healthy | `alb.tf` |
| 5-3 | SG 규칙 (ALB:80, ECS:8080 from ALB SG) | `security_groups.tf` |
| 6-1 | DynamoDB ACTIVE + PK(client_id) | `dynamodb.tf` |
| 6-2/6-3 | POST /v1/book → DynamoDB 저장 | `ecs.tf` (환경변수), `dynamodb.tf` |
| 7-1 | 로그 그룹 `/skillskorea/ecs/app` | `ecs.tf`, `variables.tf` |
| 7-2 | 로그 스트림 / 이벤트 수집 | `ecs.tf` (awslogs 드라이버 설정) |
| 7-3 | awslogs 드라이버 설정 | `ecs.tf` |
| 8-1 | 전체 연계 동작 | 모든 파일 |
| 8-2 | 불필요 리소스 없음 | 추가 리소스 생성 금지 |

---

## 리소스 요약

| 리소스 | 이름 패턴 |
|--------|-----------|
| VPC | `<선수ID>-vpc` (10.0.0.0/16) |
| Public Subnet | `<선수ID>-public-subnet-1/2` (2a, 2c) |
| IGW | `<선수ID>-igw` |
| Route Table | `<선수ID>-public-rt` |
| S3 | `<선수ID>-static-site` |
| CloudFront | S3 + ALB 오리진, Default Root: index.html |
| ECR | `<선수ID>-book-ecr` |
| ECS Cluster | `<선수ID>-book-cluster` |
| ECS Service | `<선수ID>-book-service` |
| Task Definition | `<선수ID>-book-task` |
| ALB | `<선수ID>-book-alb` |
| ALB SG | `<선수ID>-alb-sg` |
| ECS SG | `<선수ID>-ecs-sg` |
| DynamoDB | `<선수ID>-booking-table` (PK: client_id) |
| CloudWatch | `/skillskorea/ecs/app` |
| IAM | `<선수ID>-ecs-task-execution-role` / `<선수ID>-ecs-task-role` |
