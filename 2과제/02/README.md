# 2과제 (02) — Small Challenge (Workflow / Real-time data analytics / MSK)

**새 과제지 + 새 채점기준표** 기준으로 정리한 2과제 Terraform. 비번호(등번호) = **102**.

> **과제지 유의사항 12항 / 채점기준 안내**
> 기존 **3번 Cloud Event Handling 과제는 삭제**되었고, **4번 MSK 가 3번 채점항목**이 되었다.
> 이 저장소도 그에 맞춰 `module3`(EventBridge/CloudTrail, eu-west-1)을 **삭제**하고 MSK 를 `module3` 으로 재번호했다.

| 모듈 | 내용 | 리전 | 배점 | apply 위치 |
|------|------|------|------|-----------|
| `bastion` | 채점용 Bastion(전 리소스 접근) + `/opt/task2` 코드 번들 | (bastion VPC) | – | 로컬 |
| `module1` | Workflow: S3 / Lambda / DynamoDB / Step Functions | ap-southeast-1 | 7.5 | Bastion 권장 |
| `module2` | Real-time data analytics: VPC / EC2(app:5000) / ALB / Kinesis / Managed Flink | ap-northeast-2 | 7.5 | **Bastion** |
| `module3` | MSK(IAM) / Producer EC2 / Consumer Lambda×2 / DynamoDB / S3 / SNS | ap-northeast-1 | 7.5 | **Bastion** |

합계 22.5점.

---

## 0. 사전 준비
- Terraform ≥ 1.3, AWS 자격증명. 리전은 모듈 코드에 고정(위 표), provider `aws ~> 6.0`.
- 비번호는 `bibunho` 변수 기본값 **102**(module1·module3 S3 접미사). 다른 값이면 `-var="bibunho=NNN"`.

## 1. 배포

### (A) 권장: Bastion 에서 일괄 배포
```powershell
# 1) 로컬에서 Bastion 생성
cd C:\Users\competitor\2026-terraform-last\2과제\02\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command    # 접속 명령
```
```bash
# 2) Bastion 접속 후
until [ -f /opt/task2/READY ]; do sleep 5; done
BIBUNHO=102 bash /opt/task2/deploy.sh
```
`deploy.sh` 순서: module1(ap-southeast-1) → module2(ap-northeast-2) → module3(ap-northeast-1).
MSK/Flink 생성으로 **module2·3 은 수십 분** 소요될 수 있다.

### (B) 모듈 개별 배포
```bash
cd <module 디렉터리>
terraform init
terraform apply -auto-approve            # module1·module3 는 필요 시 -var="bibunho=102"
```
> module1 의 검증 provisioner 와 module2 의 Flink 생성은 `bash` 기반이라 Linux(Bastion/CloudShell)에서 실행해야 한다.

## 2. 모듈별 리소스 & 채점 대응

### module1 — Workflow (ap-southeast-1) · 7.5점
- S3 `wsc2026-student-score-bucket-102` — `input/` `processed/` `error/`
- DynamoDB `wsc2026-student-score` (PK `studentId`, SK `examDate`) — 다른 KeySchema 없음
- Lambda `wsc2026-student-score-function` — **python3.12**, handler `index.handler`, env `S3_BUCKET`/`DDB_TABLE` (소스 `src/index.py`)
  - 행 검증 → 정상행 평균·등급 DynamoDB 저장, 오류행 `error/error_<ts>_<studentId>.json`(studentId 없으면 `unknown`)
- Lambda `wsc2026-student-score-trigger` — S3 `input/*.csv` 업로드 이벤트 → Step Functions 시작 (과제지 "자동 실행은 트리거 Lambda 로 구현")
- Step Functions `wsc2026-student-score-workflow` (**STANDARD**), 입력 `{"key":"input/test.csv"}`
  - `CheckS3File → ProcessStudentData → CheckResult(Choice)` → 200 이면 `MoveToProcessed`, 그 외 `MoveToError → Fail`
  - 이동 후 **`RestoreInputPrefix`** 로 `input/` 0바이트 마커를 복원한다 (아래 ⚠ 참고)
- IAM: `wsc2026-lambda-student-role`, `wsc2026-stepfunction-student-role` (최소권한)

> ⚠ **데이터 클렌징(새 채점기준표 신규 조건)**
> "채점 시작 시 S3 버킷과 DynamoDB 데이터가 남아 있으면 **1-1·1-5·1-6 을 모두 오답**으로 간주"한다.
> - Terraform 은 폴더 placeholder 를 만들지 않는다(0바이트 마커도 데이터로 보일 수 있음).
> - `apply` 마지막 단계(`terraform_data.upload_test_csv`)에서 test.csv 로 워크플로를 1회 검증하고
>   **검증 직후 S3·DynamoDB 를 자동으로 비운다.**
> - 수동 재클렌징: `BIBUNHO=102 bash cleanup.sh`
> - 클렌징된 빈 버킷이어도 채점위원이 `input/test.csv` 를 올리면 워크플로가 `processed/`·`error/` 를 만들고
>   `input/` 마커를 복원하므로 1-1 의 `PRE error/ input/ processed/` 3종이 그대로 출력된다.

채점 기대값: 1-1 `PRE error/ input/ processed/` / 1-2 studentId HASH·examDate RANGE / 1-3 `python3.12` + env 2개 /
1-4 `wsc2026-student-score-workflow STANDARD` / 1-5 `STU1020 96.6 A` + `processed/test.csv` /
1-6 error json **정확히 4개**(STU2001·STU2002·STU2004·unknown)

### module2 — Real-time data analytics (ap-northeast-2) · 7.5점
- VPC `analytics-vpc` 10.20.0.0/16 — `analytics-pub-a/b`(10.20.0/1.0/24), `analytics-priv-a/b`(10.20.100/101.0/24),
  RTB `analytics-pub-rtb`·`analytics-priv-a-rtb`·`analytics-priv-b-rtb`, IGW `analytics-igw`, NAT `analytics-ngw`
- EC2 `wsc2026-analytics-ec2` (**t3.small**, **priv-a**, SSM) — user_data 가 `app/app.py`(port **5000**)를 systemd 서비스 **`app`** 으로 기동 → `GET /health`, `POST /order`(Kinesis put)
- ALB `wsc2026-analytics-alb` (HTTP **80**), TG `wsc2026-analytics-tg` (port **5000**, health `/health`)
- Kinesis `wsc2026-order-stream` (**ON_DEMAND**)
- Managed Flink Studio `wsc2026-analytics-flink` (**ZEPPELIN-FLINK-3_0** = Apache Flink 1.19, `null_resource`+aws CLI, **READY** 유지)
- IAM: `wsc2026-analytics-ec2-role`, `wsc2026-analytics-flink-role` (최소권한)

채점 기대값: 2-1 `analytics-priv-a` / 2-2 `80 HTTP` + `wsc2026-analytics-tg 5000` / 2-3 `ACTIVE ON_DEMAND` /
2-4 `POST /order` JSON 5필드 / 2-5 flink **READY** `ZEPPELIN-FLINK-3_0` / 2-6 `{"status":"healthy"}` / 2-7 `active`·`enabled`

> Flink Notebook 의 SQL 2종(최근 1분 주문 수, 상품별 누적 매출)은 **콘솔에서 직접 실행**해야 한다(Flink 앱 프로그래밍 금지).
> 채점은 앱 상태가 `READY` 인지 보므로 확인 후 Notebook 은 정지 상태로 둔다.

### module3 — MSK (ap-northeast-1) · 7.5점
- VPC `msk-vpc` 192.168.0.0/16 — `msk-pub-a`(0.0/24)·`msk-pub-d`(1.0/24), `msk-priv-a`(10.0/24)·`msk-priv-d`(11.0/24),
  RTB `msk-pub-rtb`·`msk-priv-a-rtb`·`msk-priv-d-rtb`, IGW `msk-igw`, NAT `msk-ngw`
- MSK `wsc2026-msk-cluster` — Kafka **3.6.0**, `kafka.t3.small`, broker 2/2AZ, **IAM 인증만**(SASL_SSL 9098), private, TLS
- Topic(producer 부팅 시 자동 생성): `wsc2026-sensor-raw`(**3** partitions / RF **2**), `wsc2026-sensor-alert`(**1** / RF **2**), key=`sensorId`
- Producer EC2 `wsc2026-sensor-producer` (t3.small, priv-a, role `wsc2026-msk-ec2-role`, SSM)
  - userdata: `kafka-python==2.2.15` + `aws-msk-iam-sasl-signer-python` 설치 → 토픽 생성 → **IAM Python producer(`producer-iam`) systemd 상시 실행**
  - 제공 Go 바이너리(`app/app`)는 이 클러스터의 TLS/IAM 엔드포인트에 접속하지 못해(`broker appears to be expecting TLS`) 사용하지 않는다.
  - 로그: `/var/log/module3-bootstrap.log`, `systemctl status producer-iam`
- Consumer Lambda ×2 — **python3.14**, handler **`index.handler`**(배포파일 `lambda.md` 기준), role `wsc2026-msk-lambda-role`(최소권한), MSK 트리거
  - `wsc2026-sensor-consumer` ← `wsc2026-sensor-raw` : 정상은 DynamoDB, 이상치는 `wsc2026-sensor-alert` 토픽으로 전달 (`lambda/raw/index.py`)
  - `wsc2026-sensor-alert-consumer` ← `wsc2026-sensor-alert` : S3 `alert/<sensorId>/<date>/<ts>.json` + SNS (`lambda/alert/index.py`)
- DynamoDB `wsc2026-sensor-data` (PK `sensorId`, SK `timestamp`), S3 `wsc2026-sensor-alert-bucket-102`, SNS `wsc2026-sensor-alert`
- 이상치 기준: temp>80 / <10, humidity>90 / <20 → `status=ALERT` + `alert_reason`

저장 타입(과제지 Attribute 표 + 채점 3-5/3-6 기준)
| Attribute | Type | 비고 |
|---|---|---|
| `sensorId` | String | PK |
| `timestamp` | String | SK, **ISO 8601 KST `YYYY-MM-DDTHH:mm:ss+09:00`** — consumer 가 어떤 입력이 와도 KST 로 정규화(`kst_timestamp`) |
| `temperature` | String | 채점 3-5 가 `temperature.S` 로 조회 → 반드시 문자열 |
| `humidity` | Number | 과제지 표 기준 숫자 |
| `location` | String | |
| `status` | String | `NORMAL` / `ALERT` |

채점 기대값: 3-1 DDB 스키마 + `head-bucket` `AccessPointAlias:false` / 3-2 두 Lambda `python3.14` /
3-3 `ACTIVE 3.6.0 kafka.t3.small True` + 토픽 2/1·2/3 / 3-4 ESM 둘 다 `Enabled` /
3-5 `sensorId`·`temperature`·`status` / 3-6 `timestamp` `+09:00` 형식 + Producer running

> ⚠ **채점기준표 3번 사전준비의 오기**: `BUCKET_NAME="wsc2026-student-score-bucket-<등번호>"` 로 적혀 있으나
> 3-1 기대 출력은 `arn:aws:s3:::wsc2026-sensor-alert-bucket-<등번호>` / `BucketRegion ap-northeast-1` 이다.
> 같은 이름의 버킷을 두 리전에 만들 수 없으므로(1번 과제 버킷은 ap-southeast-1) **alert 버킷이 정답**이다.
> 채점 시 이 점을 안내할 수 있게 알아두자.

## 3. 자기검증 스크립트
채점기준표 원문 명령을 그대로 실행해 기대값/실제값을 나란히 출력한다. (Bastion 또는 CloudShell)
```bash
number=102 bash mark1.sh                 # 1번 Workflow: 클렌징 확인 → test.csv 업로드 → 60초 후 1-1~1-6
number=102 SKIP_UPLOAD=1 bash mark1.sh   # 업로드 없이 현재 상태만 확인
bash mark2.sh                            # 2번 Real-time Data Analytics 2-1~2-7
number=102 bash mark3.sh                 # 3번 MSK 3-1~3-6 + Producer Running
BIBUNHO=102 bash cleanup.sh              # 1번 S3/DynamoDB 클렌징 (mark1 확인 후 필수)
```
> `cleanup.sh` 는 **module1 데이터만** 지운다. module3 의 `wsc2026-sensor-data`·alert 버킷은 채점 3-5/3-6 에서
> 데이터가 있어야 정답이므로 지우지 않는다.

## 4. 채점 전 체크리스트
- **공통**: `deploy.sh` 로 3모듈 apply 완료, 각 리소스 ACTIVE. Bastion 이 모든 리전 접근 가능.
- **module1**: 채점 시작 시 S3 버킷·DynamoDB **비어 있어야 함**(`cleanup.sh`). `mark1.sh` 로 확인했다면 다시 클렌징.
- **module2**: Flink Studio 는 **READY**(정지) 상태. SQL 2종 콘솔 실행 확인. `/health`·`POST /order` 응답 확인.
- **module3**: MSK ACTIVE + producer 실행 중 + DynamoDB `timestamp` 가 `+09:00` 형식인지 `mark3.sh` 로 확인.
  SNS 이메일 구독을 걸었다면 Confirm.
- **종료 전**: 실행 중인 테스트/부하 중지(과제지 유의사항 8항).

## 5. 비번호(102) 치환 지점
- `module1/main.tf` `variable "bibunho"` 기본값 → S3 `wsc2026-student-score-bucket-102`
- `module3/main.tf` `variable "bibunho"` 기본값 → S3 `wsc2026-sensor-alert-bucket-102`
- 스크립트: `deploy.sh` 의 `BIBUNHO`, `mark*.sh` 의 `number`, `cleanup.sh` 의 `BIBUNHO`

## 6. 삭제 (destroy)
```bash
# Bastion 안에서 역순
for m in module3 module2 module1; do
  ( cd /opt/task2/$m && terraform destroy -auto-approve )
done
# Flink Studio 는 CLI 생성 리소스라 별도 삭제
bash /opt/task2/module2/zeppelin-delete.sh ap-northeast-2 wsc2026-analytics-flink
```
```powershell
# 로컬에서 Bastion 제거(별도 state)
cd C:\Users\competitor\2026-terraform-last\2과제\02\bastion
terraform destroy -auto-approve
```
> 잔여 IAM 역할 확인: `wsc2026-{lambda-student,stepfunction-student,analytics-ec2,analytics-flink,msk-ec2,msk-lambda}-role`

## 7. 채점 이름이 바뀌면 수정할 위치
| 채점 이름 | 위치 |
|---|---|
| S3 버킷(1번) | `module1/main.tf` `aws_s3_bucket.score.bucket` |
| DynamoDB(1번) | `module1/main.tf` `aws_dynamodb_table.score.name` |
| Lambda/트리거(1번) | `aws_lambda_function.score.function_name` / `.trigger.function_name` |
| State Machine | `aws_sfn_state_machine.score.name` (상태명은 `definition` 내부) |
| EC2/ALB/TG/Stream(2번) | `module2/main.tf` `aws_instance.ec2.tags.Name`, `aws_lb.main.name`, `aws_lb_target_group.main.name`, `aws_kinesis_stream.orders.name` |
| Flink 앱 이름 | `module2/main.tf` `null_resource.flink` 의 `APP_NAME` + `triggers.name` |
| MSK 클러스터/토픽 | `module3/main.tf` `aws_msk_cluster.main.cluster_name` / `userdata.sh.tpl` 의 `create_topics.py` |
| Consumer Lambda | `module3/main.tf` `aws_lambda_function.raw|alert.function_name` (handler `index.handler` 이므로 파일명 `index.py` 유지) |
| DynamoDB/S3/SNS(3번) | `aws_dynamodb_table.sensor.name`, `aws_s3_bucket.alert.bucket`, `aws_sns_topic.alert.name` |

## 8. 검증 상태
- `terraform init -backend=false && terraform validate`: **module1·module2·module3·bastion 모두 Success** (Terraform v1.15.7)
- `terraform fmt -recursive -check`: 차이 없음
- Lambda 코드 문법(`py_compile`): `module1/src/{index,trigger}.py`, `module3/lambda/{raw,alert}/index.py` 통과
- 스크립트 문법(`bash -n`): `deploy.sh`, `cleanup.sh`, `mark1~3.sh`, `module3/userdata.sh.tpl`, module1 local-exec 검증 스크립트 통과
- ⚠ 실제 3개 리전 apply·엔드투엔드 채점은 배포 후 직접 확인 필요(MSK/Flink 수십 분, Flink SQL 은 콘솔 수동).
