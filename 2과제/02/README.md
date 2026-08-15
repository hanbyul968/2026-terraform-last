# 2과제 (02) — Small Challenge (Workflow / Analytics / Cloud Event Handling / MSK)

인천 제2과제 4개 요구사항을 **모듈별·리전별 Terraform**으로 구성한다. 채점기준표(vf)·과제지(vf) 기준으로
리소스 이름/런타임/포트/핸들러를 맞췄다.

| 모듈 | 내용 | 리전 | apply 위치 |
|------|------|------|-----------|
| `bastion` | 채점용 Bastion(전 리소스 접근) + `/opt/task2` 코드 번들 | (bastion VPC) | 로컬 |
| `module1` | Workflow: S3 / Lambda / DynamoDB / Step Functions | ap-southeast-1 | 로컬 가능 |
| `module2` | Analytics: VPC / EC2(app:5000) / ALB / Kinesis / Managed Flink | ap-northeast-2 | **Bastion** |
| `module3` | Cloud Event Handling: EventBridge×4 / CloudTrail / Lambda×4 / SNS | eu-west-1 | 로컬/Bastion |
| `module4` | MSK(IAM) / Producer EC2 / Consumer Lambda×2 / DynamoDB / S3 / SNS | ap-northeast-1 | **Bastion** |

> - `module1`(서버리스)·`module3`(순수 TF)은 Windows 로컬 `terraform apply` 가능.
> - `module2`(Flink Studio는 `null_resource`+aws CLI)·`module4`(MSK/토픽생성 in‑VPC)는 **Bastion(Linux)** 에서 apply.
> - **비번호(BIBUNHO)** 는 module1·module4의 S3 접미사에 쓰인다. 본 계정 비번호 = **608**.

---

## 0. 사전 준비
- Terraform ≥ 1.3, AWS 자격증명(계정 `640107381732`).
- 각 모듈은 provider `aws ~> 6.0`. 리전은 모듈 코드에 고정(위 표).

## 1. 배포

### (A) 권장: Bastion에서 일괄 배포
```powershell
# 1) 로컬에서 Bastion 생성
cd C:\Users\competitor\2026-terraform\2과제\02\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command    # 접속 명령
```
```bash
# 2) Bastion 접속 후 (aws ssm start-session --target <id> ...)
until [ -f /opt/task2/READY ]; do sleep 5; done
BIBUNHO=608 bash /opt/task2/deploy.sh
```
`deploy.sh` 순서: module1(ap-southeast-1) → module2(ap-northeast-2) → module3(eu-west-1) → module4(ap-northeast-1).
MSK/Flink 생성으로 **module2·4는 수십 분** 소요될 수 있다.

### (B) 모듈 개별 배포 (로컬/Bastion)
```bash
cd <module 디렉터리>
terraform init
terraform apply -auto-approve            # module1, module4 는 -var="bibunho=608" 필요
```

---

## 2. 모듈별 리소스 & 채점 대응

### module1 — Workflow (ap-southeast-1) · 배점 7.5
- S3 `wsc2026-student-score-bucket-608` — 폴더: `input/`(TF가 placeholder 생성), `processed/`·`error/`(워크플로가 생성)
  - ⚠ `processed/`·`error/` placeholder는 **일부러 만들지 않는다**(1‑5‑A/1‑5‑B에서 0바이트 라인 오답 방지). `input/`만 유지 → 워크플로 후에도 1‑1의 `PRE input/` 보장.
- DynamoDB `wsc2026-student-score` (PK `studentId`, SK `examDate`)
- Lambda `wsc2026-student-score-function` — **python3.12**, env `S3_BUCKET`/`DDB_TABLE` (소스 `src/index.py`)
  - 행 검증→정상행 평균·등급 DynamoDB 저장, 오류행 `error/error_<ts>_<studentId>.json`(+`unknown`)
- Lambda `wsc2026-student-score-trigger` (S3 `input/*.csv` 업로드 → Step Functions 시작)
- Step Functions `wsc2026-student-score-workflow` (**STANDARD**) — 검증→처리→processed/ 이동(오류 시 error/)
- IAM: `wsc2026-lambda-student-role`, `wsc2026-stepfunction-student-role` (최소권한)
- 채점값: 1‑1 `PRE error/ input/ processed/` / 1‑3 `python3.12` / 1‑5‑A `STU1020 96.6 A`, `processed/test.csv` / 1‑5‑B error json 4개(STU2001/2002/2004/unknown)

### module2 — Real-time analytics (ap-northeast-2) · 배점 7.5
- VPC `analytics-vpc` 10.20.0.0/16 — `analytics-pub-a/b`(10.20.0/1.0/24), `analytics-priv-a/b`(10.20.100/101.0/24), NAT `analytics-ngw`
- EC2 `wsc2026-analytics-ec2` (t3.small, **priv-a**, SSM) — user_data가 `app.py`(port **5000**)를 systemd 서비스 `app`로 기동 → `/health`, `POST /order`(Kinesis put)
- ALB `wsc2026-analytics-alb` (HTTP **80**), TG `wsc2026-analytics-tg` (port **5000**, health `/health`)
- Kinesis `wsc2026-order-stream` (**ON_DEMAND**)
- Managed Flink Studio `wsc2026-analytics-flink` (**ZEPPELIN-FLINK-3_0**, `null_resource`+aws CLI)
- IAM: `wsc2026-alaytics-ec2-role`(과제지 철자 그대로), `wsc2026-analytics-flink-role`
- 채점값: 2‑1 `analytics-priv-a` / 2‑2 `80 HTTP`,`wsc2026-analytics-tg 5000` / 2‑3 stream ACTIVE ON_DEMAND·`/order` JSON / 2‑4 flink **READY** / 2‑5 `{"status":"healthy"}` / 2‑6 `active`,`enabled`

### module3 — Cloud Event Handling (eu-west-1) · 배점 7.5
- VPC `event-vpc` 172.16.0.0/16 — `event-pub-a`(172.16.0.0/24, EC2 위치)/`event-pub-b`, IGW `event-igw`
- EC2 `wsc2026-event-ec2` (t3.micro, event-pub-a) — **정적 웹 userdata**(httpd, `hostname`), **종료방지 ON**, 프로파일/역할 `wsc2026-event-ec2-role`
- SG `wsc2026-event-sg` — 인바운드 **tcp 80 0.0.0.0/0**, 아웃바운드 전체(최소구성)
- SNS `wsc2026-event-alert`
- CloudTrail `wsc2026-event-trail` (Management **Read/Write**), 로그 S3 **`wsc2026-event-s3`**
- Lambda **4개** — 모두 **python3.14**, handler **`event_lambda.handler`**(단일 dispatcher, 소스 `lambda/event_lambda.py`), role `wsc2026-event-lambda-role`(+`iam:PassRole`)
  - `wsc2026-sg-remediation` ← `wsc2026-sg-change-rule` (SG 인바운드 추가 → 회수)
  - `wsc2026-role-remediation` ← `wsc2026-role-change-rule` (IAM 프로파일 변경 → 원복)
  - `wsc2026-termination-protection-remediation` ← `wsc2026-termination-protection-change-rule` (종료방지 해제 → 재활성)
  - `wsc2026-ec2-type-remediation` ← `wsc2026-ec2-type-change-rule` (타입 변경 → t3.micro 원복)
  - 각 Lambda는 복구 후 SNS 발행(로그에 `sns_publish` 마커 → 3‑5)
- 채점값: 3‑1 4 Lambda `python3.14`·`event_lambda.handler`, trail `IsLogging=True`, S3 `wsc2026-event-s3` / 3‑2 4 rule ENABLED→대응 Lambda / 3‑3 hostname·tcp80·userdata·프로파일 `wsc2026-event-ec2-role` / 3‑4 위반 주입 후 SG·Role·Termination·Type 전부 복구 / 3‑5 각 Lambda 로그 `sns_publish`

### module4 — MSK (ap-northeast-1) · 배점 7.5
- VPC `msk-vpc` 192.168.0.0/16 — pub-a/b(0/1.0/24), priv-a/b(10/11.0/24), NAT `msk-ngw`
- MSK `wsc2026-msk-cluster` (Kafka **3.6.0**, `kafka.t3.small`, broker 2/2AZ, **IAM 인증(9098)**, private, TLS)
- Topic(producer가 자동 생성): `wsc2026-sensor-raw`(3/2), `wsc2026-sensor-alert`(1/2)
- Producer EC2 `wsc2026-sensor-producer` (t3.small, priv-a, role `wsc2026-msk-ec2-role`)
  - userdata: **`kafka-python==2.2.15`** 고정 설치(→`kafka.sasl.oauth`), 토픽 생성, **IAM Python producer(`producer-iam`)만 실행** (Go `producer`는 TLS 미지원이라 미사용)
- Consumer Lambda×2 — **python3.14**, handler **`wsc2026.consumer_handler`**(소스 `lambda/{raw,alert}/wsc2026.py`), role `wsc2026-msk-lambda-role`(최소권한), MSK 트리거
  - `wsc2026-sensor-consumer` ← `wsc2026-sensor-raw` → 정상은 DynamoDB, 이상치는 `wsc2026-sensor-alert` 토픽으로 전달
  - `wsc2026-sensor-alert-consumer` ← `wsc2026-sensor-alert` → S3 `alert/<sensorId>/<date>/<ts>.json` + SNS
- DynamoDB `wsc2026-sensor-data` (PK `sensorId`, SK `timestamp`), S3 `wsc2026-sensor-alert-bucket-608`, SNS `wsc2026-sensor-alert`
- 이상치 기준: temp>80 / <10, humidity>90 / <20 → `status=ALERT`, `alert_reason`
- 채점값: 4‑1 DDB 스키마·S3 / 4‑2 MSK ACTIVE 3.6.0 t3.small IAM True / 4‑3 두 ESM Enabled / 4‑4 `python3.14 wsc2026.consumer_handler` / 4‑5 DynamoDB 아이템>0, S3 `alert/` 객체>0

---

## 3. 채점 전 필수 체크리스트 (직접 수행)
- **공통**: `deploy.sh`로 4모듈 apply 완료 및 각 리소스 ACTIVE 확인. Bastion은 모든 리전 접근 가능해야 함.
- **module1**: 채점 전 `processed/`·`error/`·DynamoDB를 **비우고**, 배포파일 `test.csv`를 `s3://wsc2026-student-score-bucket-608/input/`에 업로드(→워크플로 자동 실행).
- **module2**: Flink Studio Notebook은 채점 시 **READY**(정지) 상태로 둔다(RUNNING이면 2‑4 불일치). SQL 2종은 콘솔에서 실행 확인.
- **module3**: EC2 종료방지 ON, SG 인바운드 tcp80 유지. 위반 주입(3‑4)은 자동 복구되며 타입 복구(stop→start)는 시간이 걸리니 180초 내 확인. SNS 이메일 구독 시 Confirm.
- **module4**: MSK ACTIVE 후 producer가 토픽 자동 생성·발행. SSM 접속 후 `sudo cat /var/log/module4-bootstrap.log`, `systemctl status producer-iam` 확인. 데이터는 DynamoDB/`alert/`에 쌓임.
- **종료 전**: 진행 중인 테스트/부하 중지(과제지 유의사항).

## 4. 비번호(BIBUNHO=608) 치환 지점
- module1 S3 `wsc2026-student-score-bucket-608`, module4 S3 `wsc2026-sensor-alert-bucket-608`
- 주입: `deploy.sh`의 `BIBUNHO`, 또는 개별 apply 시 `-var="bibunho=608"`.

## 5. 검증 상태
- `terraform init -backend=false && terraform validate`: **module1~4 전부 통과**.
- Lambda 코드 문법(`py_compile`): module3 `event_lambda.py`, module4 `wsc2026.py` **통과**.
- ⚠ 실제 4개 리전 apply·엔드투엔드 채점은 배포 후 직접 확인 필요(MSK/Flink 수 분, Flink SQL은 콘솔 수동).

## 6. 삭제 (destroy)
```bash
# Bastion 안에서 역순
for m in module4 module3 module2 module1; do
  ( cd /opt/task2/$m && terraform destroy -auto-approve )   # module1·4 는 -var="bibunho=608"
done
```
> module3 EC2는 **종료방지(ON)** 라 destroy 전에 해제 필요:
> `aws ec2 modify-instance-attribute --region eu-west-1 --instance-id <id> --no-disable-api-termination`
```powershell
# 로컬에서 Bastion 제거(별도 state)
cd C:\Users\competitor\2026-terraform\2과제\02\bastion
terraform destroy -auto-approve
```
> IAM 역할 등 잔여물이 남으면 `wsc2026-{lambda-student,stepfunction-student,alaytics-ec2,analytics-flink,event-ec2,event-lambda,msk-ec2,msk-lambda}-role` 및 인스턴스 프로파일을 확인해 정리.
