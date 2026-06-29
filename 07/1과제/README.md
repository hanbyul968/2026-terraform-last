# 2026 전국기능경기대회 07 - 1과제 (Solution Architecture)

CloudFront 단일 엔드포인트로 정적 페이지(S3)와 Book API(ECS Fargate)를 제공하는
AWS 인프라. **2단계 구성**으로 동작한다.

```
1과제/
├── bootstrap/        ← [1단계] 로컬(Windows)에서 apply → Bastion 생성
│   ├── provider.tf
│   ├── variables.tf
│   ├── bastion.tf    # Bastion 전용 VPC/Subnet/IGW/SG, 관리자 IAM, EC2, 툴 설치 + main 업로드
│   └── outputs.tf
└── main/             ← [2단계] Bastion 안에서 apply → 채점 대상 인프라 생성
    ├── provider.tf   # aws
    ├── variables.tf  # bibunho, origin_verify_value
    ├── vpc.tf        # VPC, Subnet, IGW, NAT, DynamoDB VPC Endpoint
    ├── sg.tf
    ├── alb.tf        # ALB, TG, Listener (default 403 + X-Origin-Verify forward)
    ├── s3_cloudfront.tf
    ├── iam.tf
    ├── ecr 포함 ecs.tf
    ├── build.tf      # Docker build/push (terraform 실행 머신=Bastion 에서 수행)
    ├── dynamodb.tf
    ├── cloudwatch.tf
    ├── outputs.tf
    └── app/          # Dockerfile, book(지급 바이너리), index.html, main.jpeg
```

## 왜 2단계인가

- 로컬 Windows PC에는 Docker가 없어도 된다. 컨테이너 이미지 빌드/푸시는 Linux Bastion에서 수행한다.
- 채점 대상 구성(`main/`)은 그대로 보존되고, Bastion의 관리자 인스턴스 프로파일 권한으로 적용된다.
- 채점 대상 리소스(`skills-book-*`)와 Bastion 리소스(`skills-bastion-*`)는 완전히 분리되어,
  main 적용 후 Bastion만 따로 삭제할 수 있다 (불필요 리소스 감점 회피).

---

## 실행법 (Windows PowerShell)

### 사전 준비
- Terraform 설치 (`winget install HashiCorp.Terraform`)
- `aws configure` (region: ap-northeast-2)
- 지급받은 `book` 바이너리를 `main\app\book` 로 복사

### 1단계 — 로컬에서 Bastion 생성

```powershell
cd 2026-terraform\07\1과제\bootstrap
terraform init
terraform apply -var="bibunho=비번호" -auto-approve
```

완료되면 `bastion-key.pem` 이 생성되고, `ssh_command` / `next_steps` 가 출력된다.
Bastion에는 `main/` 구성과 `app/`(book 바이너리 포함)이 `/home/ec2-user/main` 으로
업로드되고 Docker·Terraform이 설치된다.

### 2단계 — Bastion 안에서 나머지 apply

```powershell
# 1단계 출력의 ssh_command 사용 (bootstrap 디렉터리에서)
ssh -i bastion-key.pem ec2-user@<BASTION_PUBLIC_IP>
```

```bash
# Bastion 쉘에서
./apply.sh        # = cd main && terraform init && terraform apply -auto-approve
```

`apply.sh` 가 ECR 이미지 빌드/푸시 → ECS/ALB/CloudFront/DynamoDB/CloudWatch 생성까지
수행하고 `cloudfront_domain`, `alb_dns` 를 출력한다. CloudFront 반영까지 3~5분 소요.

> `terraform.tfvars`(bibunho, origin_verify_value)는 1단계에서 Bastion에 자동 작성된다.

### 3단계 — (선택) Bastion 정리

채점 대상 인프라는 Bastion과 독립적이므로, main 생성 완료 후 로컬에서 Bastion을 삭제해도 된다.

```powershell
cd 2026-terraform\07\1과제\bootstrap
terraform destroy -var="bibunho=비번호" -auto-approve
```

---

## 검증

```bash
# (Bastion main 디렉터리에서)
# CloudFront 정적 페이지
curl -I https://$(terraform output -raw cloudfront_domain)/index.html

# ALB 직접 접근 차단 (403)
curl -s -o /dev/null -w "%{http_code}\n" http://$(terraform output -raw alb_dns)/health

# Book API
curl -X POST https://$(terraform output -raw cloudfront_domain)/v1/book \
  -H "Content-Type: application/json" \
  -d '{"client_id":"test","username":"tester","email":"t@t.com","concert_name":"skills"}'
```

---

## 주요 리소스명 (채점 대상)

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

채점 대상 구성은 모두 `main/` 안에 있다. 아래 표의 파일 경로는 `main/` 기준이다.

### VPC / 네트워크
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| VPC CIDR 변경 | `vpc.tf` | `aws_vpc.main` 의 `cidr_block` |
| Public/Private Subnet CIDR | `vpc.tf` | `aws_subnet.public/private` 의 `cidrsubnet(...)` |
| Subnet 개수 (2→N) | `vpc.tf` | `aws_subnet.public/private` 의 `count` |
| VPC Name Tag | `vpc.tf` | `aws_vpc.main` 의 `tags` |
| DynamoDB VPC Endpoint 제거 | `vpc.tf` | `aws_vpc_endpoint.dynamodb` 블록 삭제 |

### S3 / CloudFront
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| S3 버킷 이름 | `s3_cloudfront.tf` | `aws_s3_bucket.static` 의 `bucket` |
| Default Root Object | `s3_cloudfront.tf` | `default_root_object` |
| ALB Origin 경로 패턴 (`/v1/*`) | `s3_cloudfront.tf` | `ordered_cache_behavior` 의 `path_pattern` |
| Custom Header 이름 (`X-Origin-Verify`) | `s3_cloudfront.tf` + `alb.tf` | `custom_header.name` + `http_header_name` 동시 변경 |
| Custom Header 값 | `variables.tf` | `origin_verify_value` default (또는 bootstrap `-var`) |
| 정적 파일 추가 | `s3_cloudfront.tf` | `aws_s3_object` 블록 추가 |

### ALB
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| Listener 포트 (80) | `alb.tf` | `aws_lb_listener.http` 의 `port` |
| Target Group 포트 (8080) | `alb.tf` + `ecs.tf` | TG `port` + container `containerPort` |
| Health Check 경로 (`/health`) | `alb.tf` | `health_check.path` |
| ALB 이름 | `alb.tf` | `aws_lb.main` 의 `name` |

### ECR / ECS
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| ECR 리포 이름 | `ecs.tf` | `aws_ecr_repository.book` 의 `name` |
| Cluster/Service/Family/Container 이름 | `ecs.tf` | 각 `name`/`family` 및 service의 `container_name` |
| Desired Count (2→N) | `ecs.tf` | `aws_ecs_service.book` 의 `desired_count` |
| Container 포트 (8080) | `ecs.tf` + `alb.tf` | `containerPort` + TG `port` |
| Task CPU/Memory | `ecs.tf` | `cpu` / `memory` |
| 환경 변수 (AWS_REGION, TABLE_NAME) | `ecs.tf` | `environment` 배열 |
| Log Group / Stream Prefix | `ecs.tf` + `cloudwatch.tf` | `awslogs-group` / `awslogs-stream-prefix` |
| Execution/Task Role 이름 | `iam.tf` | `aws_iam_role.ecs_execution/ecs_task` 의 `name` |
| Docker 빌드/태그/푸시 로직 | `build.tf` | `terraform_data.docker_push` 의 local-exec |

### DynamoDB / KMS
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| 테이블 이름 | `dynamodb.tf` + `ecs.tf` | `aws_dynamodb_table.booking.name` + `TABLE_NAME` |
| Partition Key | `dynamodb.tf` | `hash_key` + `attribute` |
| KMS Alias | `dynamodb.tf` | `aws_kms_alias.dynamodb.name` |

### CloudWatch
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| Log Group 이름 | `cloudwatch.tf` + `ecs.tf` | `aws_cloudwatch_log_group.ecs.name` + `awslogs-group` |
| Metric Filter 이름/패턴 | `cloudwatch.tf` | `f4xx/f5xx` 의 `name` / `pattern` |
| Namespace / Metric 이름 | `cloudwatch.tf` | `metric_transformation` 및 alarm `metric_name`/`namespace` |
| Alarm 이름/Threshold/Period/Eval | `cloudwatch.tf` | `a4xx/a5xx` 의 해당 속성 |

### Bastion (bootstrap, 채점 무관)
| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| Bastion 타입 | `bootstrap/variables.tf` | `instance_type` |
| SSH 허용 CIDR | `bootstrap/variables.tf` | `ssh_cidr` |
| 설치 툴 / apply 자동화 | `bootstrap/bastion.tf` | `remote-exec` provisioner |
