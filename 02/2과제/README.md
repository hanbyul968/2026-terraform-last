# 2과제 (02) — Small Challenge

학생성적 Workflow / 실시간 분석(Kinesis+Flink) / Cloud Event Handling(EventBridge/CloudTrail 자동복구·알림) / MSK.
**로컬 PowerShell 에서 Bastion apply → SSM 접속 → Bastion 안에서 각 모듈 apply** 가 기본 흐름.
채점기준표(v2) 기준으로 리소스 이름/런타임/포트를 맞췄다.

| 모듈 | 내용 | 리전 | apply 위치 |
|------|------|------|-----------|
| module1 | Workflow: S3/Lambda/DynamoDB/Step Functions/EventBridge (학생 성적) | ap-southeast-1 | **로컬 가능** |
| module2 | Real-time analytics: VPC/EC2(app:5000)/ALB/Kinesis/Managed Flink Studio | ap-northeast-2 | Bastion |
| module3 | Cloud event handling: VPC/EC2/SG/EventBridge×4/CloudTrail/Lambda/SNS | eu-west-1 | 로컬/Bastion |
| module4 | MSK(IAM)/Producer EC2/Consumer Lambda×2/DynamoDB/S3/SNS | ap-northeast-1 | Bastion |

> module1 은 순수 서버리스(VPC 없음)라 **Windows 로컬 `terraform apply`** 로 모두 생성된다.
> module3 도 순수 TF 라 로컬 apply 가능하나, 전체 실행은 deploy.sh(Bastion)로 일괄 수행한다.
> module2 는 Flink Studio 생성에 `null_resource`(bash+aws CLI)를 쓰므로 **Bastion 에서 apply** 해야 한다.

---

## 실행 순서

### 1) Bastion 생성 (로컬 PowerShell)
```powershell
cd C:\Users\competitor\2026-terraform\02\2과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # 접속 명령 확인
```
Bastion 은 전용 VPC(`10.250.0.0/16` + public `10.250.0.0/24` + IGW)에 생성되며(계정에 default VPC 없음),
상위 `2과제` 코드 전체를 S3 로 번들 업로드해 `/opt/task2` 에 풀고 `/opt/task2/deploy.sh` 를 준비한다.

### 2) module1 은 로컬에서 바로 apply 가능 (선택)
```powershell
cd C:\Users\competitor\2026-terraform\02\2과제\module1
terraform init
terraform apply -auto-approve -var="bibunho=<비번호>"
```

### 3) Bastion 접속 후 전체 배포
```bash
# aws ssm start-session --target <id> --region ap-southeast-1
until [ -f /opt/task2/READY ]; do sleep 5; done
BIBUNHO=<비번호> bash /opt/task2/deploy.sh
```
`deploy.sh` 순서: module1(ap-southeast-1) → module2(ap-northeast-2) → module3(eu-west-1) → module4(ap-northeast-1).

---

## 모듈별 주요 리소스 (채점 대응)

### module1 — Workflow (ap-southeast-1)
- S3 `wsc2026-student-score-bucket-<비번호>` (`input/`,`processed/`,`error/`)
- DynamoDB `wsc2026-student-score` (PK `studentId`, SK `examDate`)
- Lambda **`wsc2026-student-score-function`**, Runtime **python3.12**, Env `S3_BUCKET`,`DDB_TABLE` (소스: `src/lambda_function.py`)
- Step Functions `wsc2026-student-score-workflow` (STANDARD), EventBridge `wsc2026-student-score-rule` (input/ 업로드 트리거)
- IAM: `wsc2026-lambda-student-role`, `wsc2026-stepfunction-student-role`
- **수동/채점**: 배포파일 `test.csv` 를 `s3://.../input/` 에 업로드 → 정상행은 DynamoDB+`processed/`, 오류행은 `error/error_<ts>_<studentId>.json`.

### module2 — Real-time analytics (ap-northeast-2)
- VPC `analytics-vpc` 10.20.0.0/16, subnets `analytics-pub-a/b`(0/1.0/24), `analytics-priv-a/b`(100/101.0/24), NAT
- EC2 `wsc2026-analytics-ec2` (t3.small, priv-a, SSM). user_data 가 `app.py`(port **5000**)를 **systemd 서비스 `app`** 로 기동 → `/health`, `/order`(Kinesis put)
- ALB `wsc2026-analytics-alb` (HTTP 80), TG `wsc2026-analytics-tg` (port **5000**, health `/health`)
- Kinesis `wsc2026-order-stream` (ON_DEMAND)
- Managed Flink Studio `wsc2026-analytics-flink` (ZEPPELIN-FLINK-3_0, `null_resource`+aws CLI 생성)
- IAM: `wsc2026-alaytics-ec2-role`(원문 철자 유지), `wsc2026-analytics-flink-role`
- **수동**: Flink Notebook 에서 SQL 쿼리는 콘솔에서 수행.

### module3 — Cloud Event Handling (eu-west-1)
- VPC `event-vpc` 172.16.0.0/16, `event-pub-a`(172.16.0.0/24)/`event-pub-b`(172.16.1.0/24), IGW `event-igw`, rtb `event-pub-rtb`
- EC2 `wsc2026-event-ec2`(t3.micro, event-pub-a, role `wsc2026-event-ec2-role`), SG `wsc2026-event-sg`(minimal/egress-only)
- SNS `wsc2026-event-alert`
- Lambda **`wsc2026-event-lambda`** (단일, **python3.12**, handler `index.handler`, role `wsc2026-event-lambda-role`, 소스: `lambda/index.py`)
  - 4개 EventBridge Rule 이 공통으로 이 Lambda 를 target 으로 호출 (auto-recovery + SNS alert)
- CloudTrail `wsc2026-event-trail` (Management Events **Read/Write** → EventBridge 가 API 호출 감지)
- EventBridge (각 규칙이 API 이벤트 감지):
  - `wsc2026-sg-change-rule` (AuthorizeSecurityGroupIngress) → 추가된 인바운드 규칙 회수(복구)
  - `wsc2026-role-change-rule` ((Dis)Associate/Replace IamInstanceProfile) → 알림
  - `wsc2026-ec2-terminate-rule` (TerminateInstances) → 알림
  - `wsc2026-ec2-type-change-rule` (ModifyInstanceAttribute) → 알림
- **수동**: SNS 이메일 구독 Confirm.
- **동작**: SG 22 인바운드 추가 시 자동 회수(RESTORED), 나머지 위협 이벤트는 SNS 알림(ALERT_ONLY). SNS 메시지 형식 `event/timestamp/detail/action`.

### module4 — MSK (ap-northeast-1)
- VPC `msk-vpc` 192.168.0.0/16, pub-a/b, priv-a/b, NAT
- MSK `wsc2026-msk-cluster` (Kafka **3.6.0**, `kafka.t3.small`, broker 2, IAM 인증, private, TLS)
- Topic (producer EC2 가 자동 생성): `wsc2026-sensor-raw`(3/2), `wsc2026-sensor-alert`(1/2)
- Producer EC2 `wsc2026-sensor-producer` (t3.small, priv-a, role `wsc2026-msk-ec2-role`): user_data 가 `producer.py` 배치+토픽 생성+**systemd `producer`** 기동
- Consumer Lambda×2 (**python3.14**, role `wsc2026-msk-lambda-role`, MSK 트리거):
  - `wsc2026-sensor-consumer` ← `wsc2026-sensor-raw` → DynamoDB
  - `wsc2026-sensor-alert-consumer` ← `wsc2026-sensor-alert` → S3+SNS
- DynamoDB `wsc2026-sensor-data` (PK `sensorId`, SK `timestamp`)
- S3 `wsc2026-sensor-alert-bucket-<비번호>`, SNS `wsc2026-sensor-alert`
- **자동/확인**: producer EC2 가 MSK ACTIVE 대기 후 bootstrap 조회→토픽 생성→producer 기동. SSM 접속해 `sudo cat /var/log/module4-setup.log`, `systemctl status producer` 확인.

---

## 비번호(BIBUNHO) 치환 지점
- module1 S3 = `wsc2026-student-score-bucket-<비번호>`
- module4 S3 = `wsc2026-sensor-alert-bucket-<비번호>`
- `deploy.sh` 의 `BIBUNHO` 변수(또는 로컬 apply 시 `-var="bibunho=..."`)로 주입.

## 검증 상태
- `terraform init -backend=false && terraform validate` : **module1~4 + bastion 전부 통과**.
- provider: 모듈은 aws `~> 6.0`(6.52.0), bastion 은 aws `~> 5.60`(기존 lock 5.100.0 정합).

## 삭제 순서 (destroy)
1. Bastion 안에서 채점 대상 제거(역순): `module4` → `module3` → `module2` → `module1`
   ```bash
   for m in module4 module3 module2 module1; do (cd /opt/task2/$m && terraform destroy -auto-approve); done
   ```
   (module1/4 는 `-var="bibunho=<비번호>"` 필요)
2. 로컬 PowerShell 에서 Bastion 제거(별도 state):
   ```powershell
   cd C:\Users\competitor\2026-terraform\02\2과제\bastion
   terraform destroy -auto-approve
   ```

## NEEDS-REVIEW
- module3 follows 문제지 (Cloud Event Handling, eu-west-1). (EventBridge/CloudTrail/Lambda/SNS 설계로 재구성; AWS Config 접근은 제거함.)
- MSK 토픽 생성은 TF 밖(producer EC2 kafka CLI, user_data 자동). MSK 생성에 15~30분 소요 → producer setup 은 백그라운드 재시도.
- Managed Flink Studio 는 aws CLI(`null_resource`) 생성 → apply 머신(Bastion)에 aws CLI 필요(설치됨).
