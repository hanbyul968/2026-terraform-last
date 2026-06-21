# 05 2과제

## 모듈 구성

| 모듈 | 경로 | 리전 | 내용 |
|---|---|---|---|
| 1 | `module-1/infra/` | us-east-1 | CDN (S3 + Lambda + CloudFront) |
| 2 | `module-2/` | ap-southeast-1 | Kafka + Flink + NLB |
| 3 | `module-3/infra/` | ap-northeast-2 | FastAPI + CW Agent + EventBridge |
| 4 | `module-4/` | eu-central-1 | Keycloak + OIDC + IAM |

---

## 실행 순서

### 사전 준비 (CloudShell)

```bash
cd ~
git clone https://github.com/hnmly/2026-terraform.git
```

---

### Module 1: CDN

```bash
cd ~/2026-terraform/05/2과제/module-1/infra

# Pillow 패키지 빌드 (terraform apply 전 필수)
bash build.sh

terraform init
terraform apply -var pin=<비번호>
# ⏱ ~5분

# apply 완료 후 배포파일 S3 업로드
aws s3 cp <이미지파일> s3://gj2026-cdn-bucket-<비번호>/images/ --region us-east-1
```

---

### Module 2: Real-time data analytics

```bash
cd ~/2026-terraform/05/2과제/module-2

terraform init
terraform apply
# ⏱ ~5분
# EC2 userdata에서 Kafka 자동 설치 + 토픽 생성 (약 3분 더 소요)
```

---

### Module 3: Cloud event handling

```bash
cd ~/2026-terraform/05/2과제/module-3/infra

terraform init
terraform apply -var alarm_email=<이메일주소>
# ⏱ ~3분
# alarm_email: SNS 이메일 알림 수신 주소 (채점항목 3-8)
```

---

### Module 4: Keycloak

```bash
cd ~/2026-terraform/05/2과제/module-4

terraform init
terraform apply
# ⏱ ~10분
# EC2 기동 → Keycloak 시작 대기(3분) → OIDC Provider + IAM Role 자동 생성
```

> apply 완료 후 출력된 `keycloak_public_ip` 확인
> Keycloak 관리자 콘솔: `https://<IP>/admin` (admin / admin1234!)

---

## 주의사항

- **Module 1**: `bash build.sh` 먼저 실행하지 않으면 terraform apply 실패
- **Module 3**: `alarm_email` 생략 가능 (SNS 구독 없이 알람만 생성)
- **Module 4**: EC2 재시작 시 Public IP 바뀌면 `terraform apply` 재실행 필요
- **Lambda Runtime**: PDF 명세는 `python3.14`이나 현재 `python3.12`로 설정 → AWS 지원 시 각 `main.tf`의 `runtime` 값 변경

---

## 변경 가능 항목 수정 위치

### Module 1

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| S3 버킷 이름 | `module-1/infra/main.tf` | `locals.bucket_name` |
| Lambda 함수 이름 (`gj2026-cdn-rotate`) | `module-1/infra/main.tf` | `aws_lambda_function.rotate.function_name` |
| Lambda@Edge 이름 (`gj2026-cdn-request/response`) | `module-1/infra/main.tf` | `aws_lambda_function.request/response.function_name` |
| CloudFront Behavior 경로 (`/images`) | `module-1/infra/main.tf` | `ordered_cache_behavior.path_pattern` |
| 캐시 쿼리 파라미터 (`image`, `rotate`) | `module-1/infra/main.tf` | `aws_cloudfront_cache_policy.cdn` → `query_strings.items` |
| 이미지 prefix (`images/`) | `module-1/infra/lambda/rotate.py` | `key = f"images/{image}"` |
| 회전 방향 (시계→반시계) | `module-1/infra/lambda/rotate.py` | `img.rotate(-rotate` → `img.rotate(rotate` |
| Lambda Runtime | `module-1/infra/main.tf` | `runtime` (3곳) |

### Module 2

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-data-ec2`) | `module-2/main.tf` | `aws_instance.kafka` → `tags.Name` |
| NLB 이름 (`gj2026-data-nlb`) | `module-2/main.tf` | `aws_lb.data.name` |
| Kafka 내부 포트 (`9092`) | `module-2/main.tf` | SG ingress + userdata `INTERNAL://0.0.0.0:9092` |
| Kafka 외부 포트 (`9094`) | `module-2/main.tf` | SG ingress + TG port + Listener port + userdata `EXTERNAL://0.0.0.0:9094` |
| 토픽 이름/파티션 수 | `module-2/main.tf` | userdata의 `kafka-topics.sh --create` 명령 |
| Glue DB 이름 (`real_time_analytics`) | `module-2/main.tf` | `aws_glue_catalog_database.analytics.name` |

### Module 3

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-event-ec2`) | `module-3/infra/main.tf` | `aws_instance.event` → `tags.Name` |
| 서비스 이름 (`gj2026-app`) | `module-3/infra/main.tf` | userdata의 서비스 파일명 + `systemctl` 명령 전체 |
| FastAPI 포트 (`8080`) | `module-3/infra/main.tf` | userdata의 `port=8080` + SG ingress |
| 앱 응답 메시지 (`WorldSkills 2026`) | `module-3/infra/main.tf` | userdata의 `app.py` 내 `"message"` 값 |
| SSM Parameter 경로 (`/gj2026/event/app-py`) | `module-3/infra/main.tf` | `aws_ssm_parameter.app_py.name` + IAM policy |
| 메트릭 이름 (`app_process_count`) | `module-3/infra/main.tf` | userdata의 `put-app-metric.sh` + `aws_cloudwatch_metric_alarm.app.metric_name` |
| 알람 이름 (`gj2026-event-app-alarm`) | `module-3/infra/main.tf` | `aws_cloudwatch_metric_alarm.app.alarm_name` + EventBridge `event_pattern` |
| 앱 로그 그룹 (`/gj2026/event/app-logs`) | `module-3/infra/main.tf` | `aws_cloudwatch_log_group.app_logs.name` + userdata CW Agent 설정 |
| 복구 로그 그룹 (`/gj2026/event/recovery`) | `module-3/infra/main.tf` + `lambda/recovery.py` | `aws_cloudwatch_log_group.recovery.name` + `LOG_GROUP` 변수 |
| EventBridge Rule 이름 (`gj2026-event-trigger-alarm`) | `module-3/infra/main.tf` | `aws_cloudwatch_event_rule.alarm_trigger.name` |
| Updater Lambda 이름 (`gj2026-event-updater`) | `module-3/infra/main.tf` | `aws_lambda_function.updater.function_name` + userdata `ExecStartPost` |
| Recovery Lambda 이름 (`gj2026-event-recovery`) | `module-3/infra/main.tf` | `aws_lambda_function.recovery.function_name` |
| Lambda Runtime | `module-3/infra/main.tf` | `runtime` (2곳) |

### Module 4

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-keycloak-ec2`) | `module-4/main.tf` | `aws_instance.keycloak` → `tags.Name` |
| Realm 이름 (`team`) | `module-4/main.tf` | userdata setup script의 모든 `/realms/team` + `null_resource.oidc_provider` |
| Client 이름 (`gj2026-keycloak-dev/sec`) | `module-4/main.tf` | userdata의 `for CLIENT in` 배열 + `null_resource.iam_roles` |
| Client Scope 이름 (`gj2026-keycloak-claims`) | `module-4/main.tf` | userdata의 `SCOPE_PAYLOAD.name` |
| Group 이름 (`dev-team`, `sec-team`) | `module-4/main.tf` | userdata의 `for g in dev-team sec-team` |
| 사용자/비밀번호 | `module-4/main.tf` | userdata의 `create_user` 호출 |
| Dev/Sec Role 이름 | `module-4/main.tf` | `null_resource.iam_roles` → `create_role` 호출 |
| Dev/Sec Policy 이름 | `module-4/main.tf` | `aws_iam_policy.dev/sec.name` |
| 팀 태그 키 (`team`) | `module-4/main.tf` | `aws_iam_policy.dev/sec` → `Condition.StringEquals["ec2:ResourceTag/team"]` |
| admin 비밀번호 (`admin1234!`) | `module-4/main.tf` | `variable.keycloak_admin_password.default` |
