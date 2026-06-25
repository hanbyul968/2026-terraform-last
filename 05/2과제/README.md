# 05 2과제

## 모듈 구성

루트(`05/2과제/`)에서 **한 번의 `terraform apply`로 4개 모듈 전체**를 배포합니다.
각 모듈은 서로 다른 리전이며 루트 `main.tf`에서 provider alias로 주입합니다.

| 모듈 | 경로 | 리전 | 내용 |
|---|---|---|---|
| 1 | `module1/infra/` | us-east-1 | CDN (S3 + Lambda + CloudFront) |
| 2 | `module2/` | ap-southeast-1 | Kafka + Flink Studio + NLB |
| 3 | `module3/infra/` | ap-northeast-2 | FastAPI + CW Agent + EventBridge |
| 4 | `module4/` | eu-central-1 | Keycloak + OIDC + IAM |

### 배포파일 (`files/`)

| 파일 | 사용처 | 비고 |
|---|---|---|
| `dog.png` | Module 1 | S3 `images/dog.png`로 **자동 업로드** |
| `data-app.py` | Module 2 | EC2 `/home/ec2-user/app.py`에 **바이트 그대로** 배치 (채점 2-2 SHA256 검증) |
| `event-app.py` | Module 3 | EC2 `/home/ec2-user/app.py`에 배치 |

---

## 실행 (Windows PowerShell, 한 번에 전체 apply)

> ⚠️ **CloudShell 쓰지 마세요.** 홈 용량 1GB라 provider(약 700MB)+state 저장 중 `no space left on device`로 터집니다.
> 모든 provisioner는 **Windows PowerShell 전용**으로 작성됨 (bash/Git Bash/WSL 불필요).

사전 설치(설치 후 PowerShell 새로 열기): Terraform, AWS CLI, Python — [../../사전준비/README.md](../../사전준비/README.md) 참고.

```powershell
# Windows PowerShell 에서
aws configure                                  # 자격증명 1회 설정 (안 했으면)

cd C:\Users\competitor\2026-terraform\05\2과제   # repo 클론 위치
terraform init
terraform apply -var pin=<비번호> -var alarm_email=<이메일주소>
# ⏱ ~10~15분
```

> 기본 VPC는 terraform이 자동 생성/채택(`aws_default_vpc`)하므로 별도 작업 불필요.

### state가 유실됐거나 `AlreadyExists` 충돌이 날 때

이미 만들어진 리소스가 남아 재apply가 충돌하면, 이름이 채점용 고정이라 **고아 리소스를 먼저 정리**:

```powershell
powershell -ExecutionPolicy Bypass -File cleanup.ps1 <비번호>   # 4개 리전 gj2026-* 일괄 삭제
Remove-Item terraform.tfstate*                                  # 깨진 state 초기화
terraform init
terraform apply -var pin=<비번호> -var alarm_email=<이메일주소>
```
> CloudFront/Lambda@Edge는 삭제에 1~3시간 걸립니다. CDN(module1) 재생성이 `gj2026-cdn-request/response` 충돌나면:
> `powershell -ExecutionPolicy Bypass -File delete-edge-lambdas.ps1` 를 가끔 실행해 "둘 다 정리됨" 뜬 뒤 apply.

- `pin`: CDN S3 버킷 이름 `gj2026-cdn-bucket-<비번호>`에 사용 (필수)
- `alarm_email`: Module 3 SNS 이메일 알림 주소 — **채점 3-8(SNS 이메일 알림 수신, 1.0점)** 용
  - CloudWatch Alarm이 `ALARM`으로 전환될 때 이메일 알림이 수신되는지 채점함
  - 미입력 시 SNS 구독 생략 → 3-8 점수 못 받음
  - 입력 시 **apply 후 해당 메일함의 "Confirm subscription" 클릭 필수** (AWS SNS 이메일 구독은 수동 확인 필요)
- `keycloak_admin_password`: 기본값 `admin1234!` (선택)

apply 한 번으로 자동 처리되는 것:
- Module 1: Pillow 패키지 빌드(`build.ps1` 자동 실행) → Lambda 배포 → **dog.png S3 자동 업로드**
- Module 2: Kafka 자동 설치/토픽 생성 + app.py 배치 + Zeppelin Studio 생성(AWS CLI)
- Module 3: FastAPI 배치 + CloudWatch Agent + EventBridge 복구 파이프라인
- Module 4: Keycloak 기동 → OIDC Provider + IAM Role 자동 생성

### 특정 모듈만 재배포

```bash
terraform apply -target=module.cdn      -var pin=<비번호>
terraform apply -target=module.data     -var pin=<비번호>
terraform apply -target=module.event    -var pin=<비번호> -var alarm_email=<이메일>
terraform apply -target=module.keycloak -var pin=<비번호>
```

### 출력 확인

```bash
terraform output
# cdn_cloudfront_domain, data_kafka_ec2_ip, data_nlb_dns,
# event_ec2_ip, keycloak_ip, keycloak_url
```

> Keycloak 관리자 콘솔: `https://<keycloak_ip>/admin` (admin / admin1234!)

---

## 주의사항

- **반드시 CloudShell/Linux에서 실행**: Module 1 Pillow 빌드, Module 2/4의 AWS CLI provisioner가 bash 기반
- **Module 2 Zeppelin**: Studio 노트북 셸만 자동 생성됨. 3개 Flink SQL 쿼리는 노트북에서 수동 작성 (채점 2-3~2-5)
- **Module 4**: EC2 재시작으로 Public IP가 바뀌면 `terraform apply -target=module.keycloak` 재실행
- **Lambda Runtime**: PDF 명세는 `python3.14`이나 현재 `python3.12` → AWS 지원 시 각 `main.tf`의 `runtime` 값 변경
- **AWS CLI 인증 스크립트**(`~/.aws/gj2026-keycloak-creds.sh`)는 terraform 외부 - Keycloak EC2에서 직접 작성 (채점 4-3)

---

## 트러블슈팅

### `no matching EC2 VPC found`
- 기본 VPC가 없는 리전. 최신 코드는 `aws_default_vpc`로 자동 생성하므로 `git pull` 후 재apply.

### Module 4 `local-exec ... ERROR: HTTPS 인증서를 가져오지 못했습니다`
- Keycloak EC2의 nginx(443)가 안 떠서 OIDC thumbprint를 못 가져온 경우.
- 최신 코드는 **nginx+인증서를 Keycloak보다 먼저 기동**하도록 수정됨 → `git pull` 후 재apply.
- 재apply 시 `user_data`가 바뀌면 keycloak EC2가 **교체(replace)**되고 새 IP로 nginx가 먼저 뜸 (정상).
- 그래도 실패하면 새 인스턴스에 SSM 접속해 상태 확인:
  ```bash
  sudo systemctl status nginx
  sudo tail -50 /var/log/cloud-init-output.log
  curl -k https://localhost/realms/master   # Keycloak 응답 확인
  ```

### 중간 실패 후 재실행
- 특정 모듈만: `terraform apply -target=module.<cdn|data|event|keycloak> -var pin=<비번호>`
- Keycloak IP가 바뀌면 OIDC Provider/IAM Role도 새 IP로 재생성됨 (`null_resource` 자동 재실행).

---

## 변경 가능 항목 수정 위치

### Module 1

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| S3 버킷 이름 | `module1/infra/main.tf` | `locals.bucket_name` |
| Lambda 함수 이름 (`gj2026-cdn-rotate`) | `module1/infra/main.tf` | `aws_lambda_function.rotate.function_name` |
| Lambda@Edge 이름 (`gj2026-cdn-request/response`) | `module1/infra/main.tf` | `aws_lambda_function.request/response.function_name` |
| CloudFront Behavior 경로 (`/images`) | `module1/infra/main.tf` | `ordered_cache_behavior.path_pattern` |
| 캐시 쿼리 파라미터 (`image`, `rotate`) | `module1/infra/main.tf` | `aws_cloudfront_cache_policy.cdn` → `query_strings.items` |
| 이미지 prefix (`images/`) | `module1/infra/lambda/rotate.py` | `key = f"images/{image}"` |
| 회전 방향 (시계→반시계) | `module1/infra/lambda/rotate.py` | `img.rotate(-rotate` → `img.rotate(rotate` |
| Lambda Runtime | `module1/infra/main.tf` | `runtime` (3곳) |

### Module 2

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-data-ec2`) | `module2/main.tf` | `aws_instance.kafka` → `tags.Name` |
| NLB 이름 (`gj2026-data-nlb`) | `module2/main.tf` | `aws_lb.data.name` |
| Kafka 내부 포트 (`9092`) | `module2/main.tf` | SG ingress + userdata `INTERNAL://0.0.0.0:9092` |
| Kafka 외부 포트 (`9094`) | `module2/main.tf` | SG ingress + TG port + Listener port + userdata `EXTERNAL://0.0.0.0:9094` |
| 토픽 이름/파티션 수 | `module2/main.tf` | userdata의 `kafka-topics.sh --create` 명령 |
| Glue DB 이름 (`real_time_analytics`) | `module2/main.tf` | `aws_glue_catalog_database.analytics.name` |

### Module 3

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-event-ec2`) | `module3/infra/main.tf` | `aws_instance.event` → `tags.Name` |
| 서비스 이름 (`gj2026-app`) | `module3/infra/main.tf` | userdata의 서비스 파일명 + `systemctl` 명령 전체 |
| FastAPI 포트 (`8080`) | `module3/infra/main.tf` | userdata의 `port=8080` + SG ingress |
| 앱 응답 메시지 (`WorldSkills 2026`) | `module3/infra/main.tf` | userdata의 `app.py` 내 `"message"` 값 |
| SSM Parameter 경로 (`/gj2026/event/app-py`) | `module3/infra/main.tf` | `aws_ssm_parameter.app_py.name` + IAM policy |
| 메트릭 이름 (`app_process_count`) | `module3/infra/main.tf` | userdata의 `put-app-metric.sh` + `aws_cloudwatch_metric_alarm.app.metric_name` |
| 알람 이름 (`gj2026-event-app-alarm`) | `module3/infra/main.tf` | `aws_cloudwatch_metric_alarm.app.alarm_name` + EventBridge `event_pattern` |
| 앱 로그 그룹 (`/gj2026/event/app-logs`) | `module3/infra/main.tf` | `aws_cloudwatch_log_group.app_logs.name` + userdata CW Agent 설정 |
| 복구 로그 그룹 (`/gj2026/event/recovery`) | `module3/infra/main.tf` + `lambda/recovery.py` | `aws_cloudwatch_log_group.recovery.name` + `LOG_GROUP` 변수 |
| EventBridge Rule 이름 (`gj2026-event-trigger-alarm`) | `module3/infra/main.tf` | `aws_cloudwatch_event_rule.alarm_trigger.name` |
| Updater Lambda 이름 (`gj2026-event-updater`) | `module3/infra/main.tf` | `aws_lambda_function.updater.function_name` + userdata `ExecStartPost` |
| Recovery Lambda 이름 (`gj2026-event-recovery`) | `module3/infra/main.tf` | `aws_lambda_function.recovery.function_name` |
| Lambda Runtime | `module3/infra/main.tf` | `runtime` (2곳) |

### Module 4

| 변경 항목 | 파일 | 수정 위치 |
|---|---|---|
| EC2 이름 (`gj2026-keycloak-ec2`) | `module4/main.tf` | `aws_instance.keycloak` → `tags.Name` |
| Realm 이름 (`team`) | `module4/main.tf` | userdata setup script의 모든 `/realms/team` + `null_resource.oidc_provider` |
| Client 이름 (`gj2026-keycloak-dev/sec`) | `module4/main.tf` | userdata의 `for CLIENT in` 배열 + `null_resource.iam_roles` |
| Client Scope 이름 (`gj2026-keycloak-claims`) | `module4/main.tf` | userdata의 `SCOPE_PAYLOAD.name` |
| Group 이름 (`dev-team`, `sec-team`) | `module4/main.tf` | userdata의 `for g in dev-team sec-team` |
| 사용자/비밀번호 | `module4/main.tf` | userdata의 `create_user` 호출 |
| Dev/Sec Role 이름 | `module4/main.tf` | `null_resource.iam_roles` → `create_role` 호출 |
| Dev/Sec Policy 이름 | `module4/main.tf` | `aws_iam_policy.dev/sec.name` |
| 팀 태그 키 (`team`) | `module4/main.tf` | `aws_iam_policy.dev/sec` → `Condition.StringEquals["ec2:ResourceTag/team"]` |
| admin 비밀번호 (`admin1234!`) | `module4/main.tf` | `variable.keycloak_admin_password.default` |
