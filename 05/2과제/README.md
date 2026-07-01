# 05 · 제2과제 (Small Challenge)

제61회 인천기능경기대회 · 클라우드컴퓨팅 · 제2과제. 4개 모듈을 서로 다른 리전에 배포합니다.

| 모듈 | 경로 | 리전 | 내용 | apply 위치 |
|---|---|---|---|---|
| 1 | `module1/infra/` | **us-east-1** | CDN (S3 + Lambda + Lambda@Edge + CloudFront) | **로컬(Windows) 또는 Bastion** |
| 2 | `module2/` | **ap-southeast-1** | Kafka(KRaft) + NLB + Managed Flink(Zeppelin) + Glue | **Bastion** (bash provisioner) |
| 3 | `module3/infra/` | **ap-northeast-2** | FastAPI + CW Agent/Alarm + SSM + EventBridge 자동복구 | 로컬 또는 Bastion (provisioner 없음) |
| 4 | `module4/` | **eu-central-1** | Keycloak + OIDC Provider + 팀별 IAM Role | **Bastion** (bash provisioner) |

루트 `main.tf` 가 provider alias 로 4개 모듈을 **한 번의 apply** 로 오케스트레이션합니다.

### 배포파일 (`files/`) — 수정 없이 사용

| 파일 | 사용처 | 배치 방법 |
|---|---|---|
| `dog.png` | Module 1 | S3 `images/dog.png` 로 자동 업로드 |
| `data-app.py` | Module 2 | EC2 `/home/ec2-user/app.py` 에 **바이트 그대로**(base64) — 채점 2-2 SHA256 검증 |
| `event-app.py` | Module 3 | EC2 `/home/ec2-user/app.py` 에 base64 배치 |

---

## 아키텍처: 2단계 Bastion 패턴

이 대회 계정에는 **default VPC 가 없고**, Module 2/4 는 Linux 전용 `local-exec`(AWS CLI/openssl/jq
provisioner: `zeppelin.sh`, `oidc.sh`, `iam-roles.sh`)를 사용합니다. 따라서 **Linux Bastion 안에서
전체를 apply** 하는 것이 표준 흐름입니다.

- **STAGE 1 (로컬 Windows PowerShell)** — `bastion/` 를 로컬에서 apply.
  - 전용 Bastion VPC(`10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW + 라우팅) 생성 (default VPC 미사용).
  - SSM 역할(AmazonSSMManagedInstanceCore + AdministratorAccess) + 인스턴스 프로파일.
  - 인바운드 0개(아웃바운드 443 SSM), 최신 AL2023 AMI, IMDSv2, `t3.medium`.
  - 이 `2과제` 폴더 전체를 zip 으로 묶어 부트스트랩 S3 에 업로드 → user_data 가 `/opt/task2` 로 내려받아
    도구(terraform/kubectl/helm/docker) 설치 후 `/opt/task2/deploy.sh` 생성. 완료 마커: `/opt/task2/READY`.
- **STAGE 2 (Bastion 내부)** — `bash /opt/task2/deploy.sh` 가 루트 `terraform init && apply` 로
  4개 모듈을 의존순서대로 배포. bash provisioner 들이 apply 중 올바른 시점에 자동 호출됨.

> `bastion/` 은 루트(2과제)와 **분리된 state**. 채점 직전 `bastion` 에서만 destroy 하면 Bastion(+부트스트랩
> 버킷)만 제거되고 채점 대상 리소스는 유지됩니다.

---

## STAGE 1 — Bastion 기동 (로컬 Windows PowerShell)

```powershell
cd C:\Users\competitor\2026-terraform\05\2과제\bastion
terraform init
terraform apply -var player_id=<비번호> -var pin=<비번호> -var alarm_email=<이메일주소>

# 접속 명령 확인
terraform output ssm_connect_command
```

## STAGE 2 — Bastion 접속 후 전체 배포 (SSM)

```powershell
aws ssm start-session --target <bastion_instance_id> --region ap-northeast-2
```
Bastion 안에서:
```bash
until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done   # 부트스트랩 완료 대기(2~4분)
bash /opt/task2/deploy.sh                 # 주입된 pin/alarm_email 사용
# 또는:  bash /opt/task2/deploy.sh <비번호> <이메일주소>
```
`deploy.sh` = `terraform init && terraform apply -var pin=... [-var alarm_email=...]`. ⏱ 약 10~15분.

---

## (선택) VPC 불필요 모듈 로컬 apply — Module 1 CDN

Module 1(CDN)은 **VPC 가 필요 없는 순수 서버리스**이며 Pillow 빌드가 OS 자동감지로 동작합니다
(Windows → `build.ps1`, Linux → `build.sh`, 둘 다 `--platform manylinux2014_x86_64` 로 동일 패키지 생성).
Bastion 없이 로컬 Windows 에서 바로 생성 가능합니다:

```powershell
cd C:\Users\competitor\2026-terraform\05\2과제
terraform init
terraform apply -target=module.cdn -var pin=<비번호>
```
Module 3(event)도 Linux 전용 provisioner 가 없어 `-target=module.event` 로 로컬 apply 가 가능합니다.
Module 2/4 는 bash provisioner 때문에 **반드시 Bastion(Linux)** 에서 apply 하세요.

### CDN Function URL 접근 모드 (`-var cdn_public_url=`)

채점 1-1 은 `AuthType=NONE`(공개) 기대 → **기본값 `true`**. 일부 계정(조직 RCP)은 익명 공개 Function URL
호출을 차단하므로 CDN 이 403 이면 `-var cdn_public_url=false`(AWS_IAM + CloudFront OAC 우회)로 재apply.

---

## 비번호(<비번호>) 치환 포인트

| 위치 | 변수 | 용도 |
|---|---|---|
| 루트 / 각 모듈 apply | `-var pin=<비번호>` | Module 1 S3 버킷 `gj2026-cdn-bucket-<비번호>` |
| Bastion apply | `-var player_id=<비번호>` | Bastion 리소스 접두어 + 부트스트랩 버킷명(식별용, destroy 대상) |

나머지 리소스 이름은 채점 고정값(`gj2026-*`)이라 치환하지 않습니다.

---

## 수동 단계 (apply 후)

- **Module 2 Flink 노트북 SQL (채점 2-3~2-5)**: Zeppelin Studio 앱은 terraform 이 생성·시작하지만,
  소스/싱크 테이블 + 3개 쿼리는 콘솔 노트북에 붙여넣어야 합니다 → **[module2/FLINK-NOTEBOOK.md](module2/FLINK-NOTEBOOK.md)**.
- **Module 3 SNS 이메일 구독 (채점 3-8)**: `-var alarm_email=` 입력 시 apply 후 해당 메일함의
  **"Confirm subscription"** 클릭 필수(AWS SNS 이메일 구독 수동 확인).
- **Module 4 Keycloak 자격증명 스크립트 (채점 4-3)**: `~/.aws/gj2026-keycloak-creds.sh` 는 이제
  `gj2026-keycloak-ec2` user_data 가 **자동 생성**합니다(ec2-user 홈). 채점 시 CloudShell 로 복사해
  사용: `aws configure set credential_process "~/.aws/gj2026-keycloak-creds.sh dev dev-user" --profile gj2026-keycloak-dev`.
  - 흐름: Keycloak ROPC(public client) → ID Token → `sts assume-role-with-web-identity`
    (RoleSessionName=`keycloak-session`) → credential_process JSON.
  - EC2 재시작으로 Public IP 가 바뀌면 `terraform apply -target=module.keycloak` 재실행(OIDC Provider/IAM Role/스크립트 재생성).

---

## 출력

```bash
terraform output
# cdn_cloudfront_domain, cdn_s3_bucket, data_kafka_ec2_ip, data_nlb_dns,
# event_ec2_ip, keycloak_ip, keycloak_url
```
Keycloak 관리자 콘솔: `https://<keycloak_ip>/admin` (admin / admin1234!).

---

## 리소스 이름 & 채점 매핑 요약

**Module 1 CDN (us-east-1)** — Lambda `gj2026-cdn-rotate`(Function URL, python3.14), Lambda@Edge
`gj2026-cdn-request`/`gj2026-cdn-response`, CloudFront + Behavior `/images`, 캐시키 `image`/`rotate`,
S3 `gj2026-cdn-bucket-<비번호>`(퍼블릭 차단, OAC).

**Module 2 Real-time analytics (ap-southeast-1)** — EC2 `gj2026-data-ec2`(Kafka KRaft, 9092 내부/9094 외부),
NLB `gj2026-data-nlb`(Internet-facing, TCP 9094), 토픽 order-logs(2)/error-stats(1)/high-latency(1)/anomaly(1),
Glue DB `real_time_analytics`, Managed Flink Zeppelin `gj2026-data-zeppelin`.

**Module 3 Cloud event handling (ap-northeast-2)** — EC2 `gj2026-event-ec2`, 서비스 `gj2026-app`(8080),
SSM `/gj2026/event/app-py`, 메트릭 `app_process_count`(GJ2026/Events), Alarm `gj2026-event-app-alarm`,
로그그룹 `/gj2026/event/app-logs`·`/gj2026/event/recovery`, Lambda `gj2026-event-updater`/`gj2026-event-recovery`,
EventBridge `gj2026-event-trigger-alarm`, SNS `gj2026-event-alarm-topic`.

**Module 4 Keycloak (eu-central-1)** — EC2 `gj2026-keycloak-ec2`(HTTPS via nginx), Realm `team`,
Client `gj2026-keycloak-dev`/`gj2026-keycloak-sec`(public), Client Scope `gj2026-keycloak-claims`(role/team/group mapper),
Group `dev-team`/`sec-team`, OIDC Provider `https://<IP>/realms/team`,
Role `gj2026-keycloak-dev-role`/`gj2026-keycloak-sec-role`, Policy `gj2026-keycloak-dev-policy`/`gj2026-keycloak-sec-policy`.

---

## 변경 가능 항목 수정 위치

### Module 1
| 항목 | 파일 | 위치 |
|---|---|---|
| S3 버킷 이름 | `module1/infra/main.tf` | `locals.bucket_name` |
| rotate/@Edge 함수 이름 | `module1/infra/main.tf` | `aws_lambda_function.*.function_name` |
| Behavior 경로 `/images` | `module1/infra/main.tf` | `ordered_cache_behavior.path_pattern` |
| 캐시 쿼리 파라미터 | `module1/infra/main.tf` | `aws_cloudfront_cache_policy.cdn` → `query_strings.items` |
| 회전 방향 | `module1/infra/lambda/rotate.py` | `img.rotate(-rotate` |
| Lambda Runtime | `module1/infra/main.tf` | `runtime` (3곳) |

### Module 2
| 항목 | 파일 | 위치 |
|---|---|---|
| EC2/NLB 이름 | `module2/main.tf` | `aws_instance.kafka` / `aws_lb.data.name` |
| Kafka 포트(9092/9094) | `module2/main.tf` | SG ingress + TG/Listener + userdata listeners |
| 토픽 이름/파티션 | `module2/main.tf` | userdata `kafka-topics.sh --create` |
| Glue DB | `module2/main.tf` | `aws_glue_catalog_database.analytics.name` |

### Module 3
| 항목 | 파일 | 위치 |
|---|---|---|
| EC2/서비스 이름·포트 | `module3/infra/main.tf` | `aws_instance.event` / userdata systemd + SG |
| 메트릭/알람/EventBridge 이름 | `module3/infra/main.tf` | `aws_cloudwatch_*` + userdata put-app-metric |
| SSM 경로·로그그룹 | `module3/infra/main.tf` | `aws_ssm_parameter.app_py` / `aws_cloudwatch_log_group.*` |
| Lambda Runtime | `module3/infra/main.tf` | `runtime` (2곳) |

### Module 4
| 항목 | 파일 | 위치 |
|---|---|---|
| EC2/Realm/Client/Group 이름 | `module4/main.tf` | userdata setup script |
| Dev/Sec Policy 태그 조건 | `module4/main.tf` | `aws_iam_policy.dev/sec` → `Condition ec2:ResourceTag/team` |
| admin 비밀번호 | `module4/main.tf` | `variable.keycloak_admin_password.default` |
| 자격증명 스크립트 매핑 | `module4/main.tf` | userdata `gj2026-keycloak-creds.sh` (team→role/client/pw) |

---

## 검증(validate) 상태

`terraform init -backend=false && terraform validate` — 전 root 통과:
`(root)`, `bastion`, `module1/infra`, `module2`, `module3/infra`, `module4` → 모두 **Success**.

> ⚠️ `terraform apply`/`destroy` 는 실행하지 않았습니다(대회 당일 적용용 템플릿).

---

## 🧹 삭제 순서

1. **채점 완료 후** Bastion 안에서 채점 대상 destroy:
   ```bash
   cd /opt/task2 && terraform destroy -auto-approve -var pin=<비번호>
   ```
   - CloudFront/Lambda@Edge 는 삭제에 1~3시간 소요. `gj2026-cdn-request/response` 충돌 시
     `delete-edge-lambdas.sh` 를 재실행 후 진행.
   - 고아 리소스가 남아 재apply 충돌 시(이름 고정) `cleanup.ps1 <비번호>` 로 4개 리전 `gj2026-*` 일괄 정리 후
     `Remove-Item terraform.tfstate*` → 재init/apply.
2. **채점 직전 또는 정리 시** 로컬에서 Bastion 제거(별도 state):
   ```powershell
   cd C:\Users\competitor\2026-terraform\05\2과제\bastion
   terraform destroy -auto-approve -var player_id=<비번호> -var pin=<비번호>
   ```

---

## 트러블슈팅

- **Module 4 OIDC thumbprint 실패**: Keycloak EC2 nginx(443) 미기동. 최신 코드는 nginx/인증서를 Keycloak
  보다 먼저 기동. SSM 접속해 `systemctl status nginx`, `tail -50 /var/log/cloud-init-output.log`,
  `curl -k https://localhost/realms/master` 확인.
- **Module 1 CDN 403**: 공개 Function URL 차단 계정 → `-var cdn_public_url=false` 재apply.
- **중간 실패**: 특정 모듈만 `terraform apply -target=module.<cdn|data|event|keycloak> -var pin=<비번호>`.
