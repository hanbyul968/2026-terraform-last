# 🏆 WSC2026 인천 제2과제 (Small Challenge) — AWS 콘솔 풀이

> 제61회 인천기능경기대회 `과제지_vf` + `채점기준표_vf` + `채점스크립트/vf/mark2-*.sh` 기준
> **콘솔 클릭 순서** 가이드. 경기시간 **4시간**, 배점 **30점**.
> 문서 안의 `<비번호>`, `<ACCOUNT_ID>` 등은 본인 값으로 바꿔 입력한다.

---

## ⚠️ 시작 전 반드시 읽을 3가지

### 1. 모듈마다 리전이 전부 다르다 (제일 많이 틀리는 부분)

| 모듈 | 주제 | 리전 | 배점 | 채점 스크립트 |
|:-:|---|---|:-:|---|
| 1 | Workflow | **싱가포르 `ap-southeast-1`** | 7.5 | `mark2-1.sh` |
| 2 | Real-time Data Analytics | **서울 `ap-northeast-2`** | 7.5 | `mark2-2.sh` |
| 3 | Cloud Event Handling | **아일랜드 `eu-west-1`** | 7.5 | `mark2-3.sh` |
| 4 | MSK | **도쿄 `ap-northeast-1`** | 7.5 | `mark2-4.sh` |
| | | **합계** | **30** | |

### 2. 🚨 모듈 3은 과제지와 채점스크립트가 서로 다르다

`과제지_vf` / `module3/lambda.md` 와 실제 `mark2-3.sh` 가 요구하는 리소스 이름이 **불일치**한다.

| | 과제지·lambda.md | 채점스크립트 `mark2-3.sh` |
|---|---|---|
| Lambda | `wsc2026-sg-remediation`<br>`wsc2026-role-remediation`<br>`wsc2026-ec2-terminate-alert`<br>`wsc2026-ec2-type-remediation` | `wsc2026-sg-remediation`<br>`wsc2026-ec2-terminate-alert`<br>**`wsc2026-ec2-stop-remediation`**<br>**`wsc2026-tag-alert`** |
| EventBridge | sg-change / role-change / ec2-terminate / ec2-type-change | **`wsc2026-ec2-stop-rule`**, `wsc2026-ec2-terminate-rule` |
| 그 외 | — | **AWS Config 규칙 2개** (`wsc2026-sg-ssh-rule`, `wsc2026-required-tags-rule`) |

**대응 전략: 둘 다 만든다.** 겹치는 2개(`sg-remediation`, `ec2-terminate-alert`) + 과제지 전용 2개 + 채점 전용 2개 = **Lambda 6개**, 룰 6개, Config 규칙 2개.
어느 쪽 기준으로 채점하든 만점이 나온다. 시간이 부족하면 **채점스크립트 쪽을 우선**한다 (실제 점수는 스크립트로 매겨진다).

### 3. 채점 직전 리소스 상태 (과제 종료 전 체크)

- 모듈 1: `input/` 은 비고, `processed/test.csv` 1개, `error/` 에 JSON **정확히 4개**, DynamoDB 에 학생 5명
- 모듈 2: `app` 서비스 active/enabled, **Flink 노트북은 `READY`(중지) 상태로 둔다** ← RUNNING 이면 오답
- 모듈 3: EC2 running, SG 인바운드 **0개**
- 모듈 4: Producer 실행 중, DynamoDB 에 센서 데이터 쌓이는 중

---

## 📋 세부 배점 체크리스트

| 모듈 | # | 세부 항목 | 배점 | ☐ |
|:-:|:-:|---|:-:|:-:|
| 1 | 1-1 | S3 Bucket + Folder Structure | 1.0 | ☐ |
| 1 | 1-2 | DynamoDB Table + Key Schema | 1.0 | ☐ |
| 1 | 1-3 | Lambda Function + Runtime + Env | 1.5 | ☐ |
| 1 | 1-4 | Step Functions State Machine | 1.0 | ☐ |
| 1 | 1-5-A | Workflow Result (Normal) | 1.5 | ☐ |
| 1 | 1-5-B | Workflow Result (Error) | 1.5 | ☐ |
| 2 | 2-1 | EC2 Instance (private subnet) | 1.0 | ☐ |
| 2 | 2-2 | ALB Resources | 1.0 | ☐ |
| 2 | 2-3-A | Kinesis Stream | 1.0 | ☐ |
| 2 | 2-3-B | Kinesis Data (POST /order) | 1.0 | ☐ |
| 2 | 2-4 | Flink Application | 1.0 | ☐ |
| 2 | 2-5 | Application Health | 1.0 | ☐ |
| 2 | 2-6 | Systemd Service | 1.5 | ☐ |
| 3 | 3-1 | CloudTrail | 0.5 | ☐ |
| 3 | 3-2 | SNS Topic | 0.5 | ☐ |
| 3 | 3-3 | Lambda Functions | 1.5 | ☐ |
| 3 | 3-4 | EventBridge Rules | 2.0 | ☐ |
| 3 | 3-5 | SG Remediation Test | 1.5 | ☐ |
| 3 | 3-6 | EC2 Type/Stop Remediation Test | 1.5 | ☐ |
| 4 | 4-1 | Resources (DynamoDB + S3) | 1.0 | ☐ |
| 4 | 4-2 | Lambda Functions | 1.0 | ☐ |
| 4 | 4-3 | MSK Cluster Configuration | 2.0 | ☐ |
| 4 | 4-4 | MSK Trigger Mapping | 1.5 | ☐ |
| 4 | 4-5-A | Data Processing Result | 1.0 | ☐ |
| 4 | 4-5-B | Producer Running | 1.0 | ☐ |

---

## 🧰 준비물

- AWS 콘솔 로그인 (관리자급) + **CloudShell** (리전별로 따로 열림)
- 배포파일은 전부 [`files/`](files) 에 복사해 뒀다 (TODO 완성본 포함)

| 경로 | 내용 |
|---|---|
| [`files/module1/`](files/module1) | 완성된 `lambda_function.py`, 트리거 Lambda, Step Functions ASL, IAM 정책, `test.csv` |
| [`files/module2/`](files/module2) | `app.py`, `requirements.txt`, `user-data.sh`, `app.service`, Flink SQL, IAM 정책 |
| [`files/module3/`](files/module3) | Lambda 6개, EventBridge 패턴 모음, IAM 정책 |
| [`files/module4/`](files/module4) | Go `app` 바이너리, Consumer Lambda 2개, `producer.service`, 토픽 생성 스크립트, IAM 정책 |

---

## ⏱️ 4시간 권장 순서

| 시간 | 작업 |
|---|---|
| 00:00 – 00:10 | **모듈 4 MSK 클러스터 생성 먼저 시작** (30~40분 걸림, 백그라운드로 굽는다) |
| 00:10 – 00:55 | 모듈 1 (Workflow) — 가장 독립적, 확실한 7.5점 |
| 00:55 – 01:50 | 모듈 2 (VPC/EC2/ALB/Kinesis/Flink) |
| 01:50 – 02:40 | 모듈 3 (Event Handling) |
| 02:40 – 03:40 | 모듈 4 마무리 (토픽, Lambda, 트리거, Producer) |
| 03:40 – 04:00 | 채점 스크립트 4개 직접 돌려보고 최종 상태 정리 |

> MSK는 **제일 먼저** 만들어 두지 않으면 시간이 모자란다. VPC → MSK 클러스터 생성 요청까지만 먼저 해두고 다른 모듈로 넘어간다.

---
---

# 모듈 1. Workflow — `ap-southeast-1` (싱가포르)

S3 업로드 → Lambda 트리거 → Step Functions → 성적 처리 Lambda → DynamoDB.

> 콘솔 우측 상단 리전이 **싱가포르**인지 확인하고 시작.

## 1-1. S3 버킷 + 폴더 3개

1. **S3** → `버킷 만들기`
2. 버킷 이름: `wsc2026-student-score-bucket-<비번호>`
3. 리전: **아시아 태평양(싱가포르) ap-southeast-1**
4. 나머지 기본값 → `버킷 만들기`
5. 버킷 진입 → `폴더 만들기` 를 3번 반복해서 생성:
   - `input/`
   - `processed/`
   - `error/`

> ✅ 채점 `1-1` 은 `aws s3 ls` 결과에 `PRE error/`, `PRE input/`, `PRE processed/` 3줄이 나오는지 본다.
> 폴더는 **비어 있어도 콘솔에서 만들면 0바이트 객체로 남아 `PRE` 로 잡힌다.**

## 1-2. DynamoDB 테이블

1. **DynamoDB** → `테이블 생성`
2. 테이블 이름: `wsc2026-student-score`
3. 파티션 키: `studentId` — **문자열**
4. 정렬 키: `examDate` — **문자열**
5. 설정: 기본값 (온디맨드) → `테이블 생성`

## 1-3. IAM Role 2개

### `wsc2026-lambda-student-role`

1. **IAM** → `역할` → `역할 생성`
2. 신뢰할 수 있는 엔터티: **AWS 서비스** → **Lambda**
3. 권한: 일단 `AWSLambdaBasicExecutionRole` 만 선택 → 역할 이름 `wsc2026-lambda-student-role` → 생성
4. 생성된 역할 → `권한 추가` → `인라인 정책 생성` → **JSON** 탭
5. [`files/module1/iam-lambda-policy.json`](files/module1/iam-lambda-policy.json) 내용 붙여넣기 (`<비번호>`, `<ACCOUNT_ID>` 치환)
6. 정책 이름 `wsc2026-lambda-student-policy` → 생성

> 이 역할 하나로 **성적 처리 Lambda + 트리거 Lambda** 를 모두 쓴다. (정책에 `states:StartExecution` 이 들어있는 이유)

### `wsc2026-stepfunction-student-role`

1. **IAM** → `역할 생성` → **AWS 서비스** → **Step Functions**
2. 역할 이름 `wsc2026-stepfunction-student-role` → 생성
3. 인라인 정책으로 [`files/module1/iam-stepfunction-policy.json`](files/module1/iam-stepfunction-policy.json) 추가

## 1-4. 성적 처리 Lambda

1. **Lambda** → `함수 생성` → `새로 작성`
2. 함수 이름: `wsc2026-student-score-function`
3. 런타임: **Python 3.12**
4. 아키텍처: 기본값
5. `기본 실행 역할 변경` → `기존 역할 사용` → `wsc2026-lambda-student-role`
6. `함수 생성`

### 코드 배포

7. 코드 소스에서 기본 `lambda_function.py` 를 열고, [`files/module1/lambda_function.py`](files/module1/lambda_function.py) 내용으로 **전체 교체**
8. 파일 이름을 `index.py` 로 바꾼다 (우클릭 → Rename)
9. `Deploy` 클릭

### 핸들러/환경변수/타임아웃

10. `런타임 설정` → `편집` → 핸들러: **`index.handler`**
11. `구성` → `환경 변수` → `편집`:

| 키 | 값 |
|---|---|
| `S3_BUCKET` | `wsc2026-student-score-bucket-<비번호>` |
| `DDB_TABLE` | `wsc2026-student-score` |

12. `구성` → `일반 구성` → 제한 시간 **1분** 으로 늘림

> ✅ 채점 `1-3` 은 함수명 + `python3.12` + 환경변수 2개를 그대로 비교한다. 오타 주의.

### 완성한 TODO 요약

| 함수 | 구현 내용 |
|---|---|
| `calculate_grade` | 90↑ A / 80↑ B / 70↑ C / 60↑ D / 나머지 F |
| `save_student` | 5과목(`korean,english,math,science,history`) 평균을 `Decimal` 로 계산 → 등급 산출 → `put_item` |

> `average` 는 **Number** 타입이어야 한다 (`Decimal(str(...))`). float 을 그대로 넣으면 boto3 가 에러를 낸다.
> STU1020 = (100+98+92+97+96)/5 = **96.6 → A** 가 채점 정답값이다.

## 1-5. Step Functions State Machine

1. **Step Functions** → `상태 머신 생성` → `빈 템플릿` → 우측 상단 `코드` 탭 선택
2. [`files/module1/workflow.asl.json`](files/module1/workflow.asl.json) 내용 붙여넣기 (버킷명 4곳 치환)
3. `구성` 탭:
   - 이름: `wsc2026-student-score-workflow`
   - 유형: **Standard**
   - 실행 역할: **기존 역할 사용** → `wsc2026-stepfunction-student-role`
4. `생성`

### 워크플로 구조

```
CheckS3File (s3:headObject)
      ├─ 실패 → FileNotFound (Fail)
      ↓
ProcessStudentData (lambda:invoke, Retry 2s ×3 backoff 2.0)
      ↓
CheckResult (Choice)
      ├─ statusCode == 200 → MoveToProcessed → DeleteInputAfterProcessed → End
      └─ Otherwise         → MoveToError → DeleteInputAfterError → WorkflowFailed (Fail)
```

> `Retry` 의 `BackoffRate: 2` 가 workflow.md 의 "실패할수록 대기 시간 증가(Exponential Backoff)" 요구사항이다. 빼먹지 말 것.
>
> S3 `MoveObject` 라는 API 는 없다. **copyObject + deleteObject 두 State** 로 나눠야 한다.

## 1-6. 트리거 Lambda + S3 이벤트

1. **Lambda** → `함수 생성` → 이름 `wsc2026-student-score-trigger`, 런타임 **Python 3.12**
2. 실행 역할: `wsc2026-lambda-student-role` (기존 역할 사용)
3. 코드를 [`files/module1/trigger_lambda.py`](files/module1/trigger_lambda.py) 로 교체, 파일명 `index.py`, 핸들러 `index.handler`, `Deploy`
4. 환경 변수 추가:

| 키 | 값 |
|---|---|
| `STATE_MACHINE_ARN` | `arn:aws:states:ap-southeast-1:<ACCOUNT_ID>:stateMachine:wsc2026-student-score-workflow` |

5. **S3 버킷** → `속성` → `이벤트 알림` → `이벤트 알림 생성`
   - 이름: `csv-upload`
   - 접두사: `input/`
   - 접미사: `.csv`
   - 이벤트 유형: **모든 객체 생성 이벤트** (`s3:ObjectCreated:*`)
   - 대상: **Lambda 함수** → `wsc2026-student-score-trigger`
6. 저장 (S3가 Lambda 리소스 정책을 자동으로 추가해 준다)

## 1-7. 실행 & 검증

1. **S3** → 버킷 → `input/` → [`files/module1/test.csv`](files/module1/test.csv) 업로드
2. **Step Functions** → 상태 머신 → `실행` 탭에서 자동 실행 확인 (수 초 내 `성공`)
3. CloudShell(싱가포르)에서 확인:

```bash
BUCKET_NAME="wsc2026-student-score-bucket-<비번호>"

# 1-5-A : STU1020 96.6 A  +  processed/test.csv
aws dynamodb get-item --table-name wsc2026-student-score \
  --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
  --query "Item.[studentId.S,average.N,grade.S]" --output text
aws s3 ls s3://$BUCKET_NAME/processed/

# 1-5-B : error/ 에 JSON 정확히 4개
aws s3 ls s3://$BUCKET_NAME/error/
```

기대 결과:

```
STU1020  96.6  A
2026-05-31 22:58:16  497 test.csv

error_<timestamp>_STU2001.json    # history 누락      → MISSING_FIELD
error_<timestamp>_STU2002.json    # english=eighty    → INVALID_FORMAT
error_<timestamp>_STU2004.json    # name 누락, math=A → MISSING_FIELD
error_<timestamp>_unknown.json    # studentId 누락    → MISSING_FIELD
```

> ⚠️ **재실행 시 반드시 `error/` 를 비우고 다시 하라.** 파일명에 timestamp 가 들어가서 실행할 때마다 4개씩 쌓인다.
> 채점은 "**4개 이외의 값이 출력되면 오답**" 이다.
>
> ⚠️ 워크플로가 정상(200) 이면 `test.csv` 는 `processed/` 로 간다. `error/` 에는 **JSON 4개만** 있어야 하고 `test.csv` 가 있으면 안 된다.

---
---

# 모듈 2. Real-time Data Analytics — `ap-northeast-2` (서울)

EC2(Flask) → Kinesis Data Stream → Managed Flink Studio Notebook.

## 2-1. VPC

**VPC** → `VPC 생성` → **VPC 등** 선택 (VPC and more)

| 항목 | 값 |
|---|---|
| 이름 태그 자동 생성 | `analytics` |
| IPv4 CIDR | `10.20.0.0/16` |
| AZ 수 | **2** (`ap-northeast-2a`, `ap-northeast-2b`) |
| 퍼블릭 서브넷 | 2 |
| 프라이빗 서브넷 | 2 |
| NAT 게이트웨이 | **1개 AZ 에** |
| VPC 엔드포인트 | 없음 |

`서브넷 CIDR 블록 사용자 지정` 을 눌러 정확히 맞춘다:

| Subnet | CIDR | Route Table | 인터넷 |
|---|---|---|---|
| `analytics-pub-a` | `10.20.0.0/24` | `analytics-pub-rtb` | IGW |
| `analytics-pub-b` | `10.20.1.0/24` | `analytics-pub-rtb` | IGW |
| `analytics-priv-a` | `10.20.100.0/24` | `analytics-priv-a-rtb` | NAT |
| `analytics-priv-b` | `10.20.101.0/24` | `analytics-priv-b-rtb` | NAT |

생성 후 **이름을 위 표대로 직접 수정**한다 (VPC 마법사는 `analytics-subnet-public1-...` 식으로 만든다).
- VPC: `analytics-vpc` / IGW: `analytics-igw` / NAT: `analytics-ngw`
- 라우팅 테이블 3개도 이름 변경. 프라이빗 RTB 가 1개만 생겼으면 **1개 더 만들어** priv-b 에 연결한다.

> ✅ 채점 `2-1` 은 EC2 가 붙은 서브넷의 **Name 태그가 `analytics-priv-a`** 인지 본다. 이름 태그가 생명이다.

## 2-2. Kinesis Data Stream

1. **Kinesis** → `데이터 스트림 생성`
2. 이름: `wsc2026-order-stream`
3. 용량 모드: **온디맨드**
4. 생성

## 2-3. IAM Role — `wsc2026-alaytics-ec2-role`

> ⚠️ 과제지 오타 그대로 **`alaytics`** (n 없음) 로 만든다. 과제지 표기가 정답이다.

1. **IAM** → `역할 생성` → **AWS 서비스** → **EC2**
2. 권한: `AmazonSSMManagedInstanceCore` 체크 (채점이 SSM 을 쓴다)
3. 이름 `wsc2026-alaytics-ec2-role` → 생성
4. 인라인 정책으로 [`files/module2/iam-ec2-policy.json`](files/module2/iam-ec2-policy.json) 추가 (Kinesis PutRecord)

## 2-4. 보안 그룹 2개

**EC2** → `보안 그룹` → 생성

| 이름 | 인바운드 | 아웃바운드 |
|---|---|---|
| `wsc2026-analytics-alb-sg` | TCP 80 ← `0.0.0.0/0` | 전체 허용 |
| `wsc2026-analytics-ec2-sg` | TCP 5000 ← **`wsc2026-analytics-alb-sg`** | 전체 허용 |

> EC2 SG 인바운드는 CIDR 이 아니라 **ALB 보안그룹 ID** 를 소스로 지정한다 ("ALB 통해서만 접근" 요구사항).
> SSM 은 아웃바운드 443 만 있으면 되므로 인바운드 22 는 열지 않는다.

## 2-5. EC2 생성

1. **EC2** → `인스턴스 시작`
2. 이름: `wsc2026-analytics-ec2`
3. AMI: **Amazon Linux 2023**
4. 인스턴스 유형: **t3.small**
5. 키 페어: `키 페어 없이 계속`
6. 네트워크 설정 `편집`:
   - VPC: `analytics-vpc`
   - 서브넷: **`analytics-priv-a`**
   - 퍼블릭 IP 자동 할당: **비활성화**
   - 기존 보안 그룹: `wsc2026-analytics-ec2-sg`
7. 고급 세부 정보 → IAM 인스턴스 프로파일: `wsc2026-alaytics-ec2-role`
8. `인스턴스 시작`

## 2-6. 애플리케이션 배포 (SSM Session Manager)

EC2 가 running 되고 SSM 에 등록되면 (2~3분) **Session Manager** 로 접속한다.

```bash
sudo -i
dnf install -y python3.12 python3.12-pip
mkdir -p /opt/app && cd /opt/app
```

`app.py` 와 `requirements.txt` 를 올리는 가장 빠른 방법 — **히어독으로 직접 붙여넣기**:

```bash
cat >/opt/app/requirements.txt <<'EOF'
flask==3.1.1
boto3==1.35.0
gunicorn==23.0.0
EOF

cat >/opt/app/app.py <<'EOF'
<files/module2/app.py 내용 전체 붙여넣기>
EOF
```

가상환경 + 의존성 설치:

```bash
python3.12 -m venv /opt/app/venv
/opt/app/venv/bin/pip install -r /opt/app/requirements.txt
```

## 2-7. systemd 서비스 등록 (⭐ 1.5점)

```bash
cat >/etc/systemd/system/app.service <<'EOF'
[Unit]
Description=WSC2026 order log producer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/app
Environment=STREAM_NAME=wsc2026-order-stream
Environment=AWS_REGION=ap-northeast-2
Environment=AWS_DEFAULT_REGION=ap-northeast-2
ExecStart=/opt/app/venv/bin/gunicorn -w 2 -b 0.0.0.0:5000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app
systemctl is-active app && systemctl is-enabled app   # active / enabled
curl -s localhost:5000/health                          # {"status":"healthy"}
```

> ⚠️ 서비스 이름은 반드시 **`app`** (`app.service`). 채점이 `systemctl is-active app` 을 그대로 실행한다.
> ⚠️ `app.py` 는 `STREAM_NAME`/`AWS_REGION` 이 없으면 **import 시점에 죽는다.** systemd `Environment=` 로 꼭 넣어야 한다.
> ⚠️ `enable --now` 를 해야 `is-enabled` 가 `enabled` 로 나온다 (재부팅 자동 실행 요구사항).

## 2-8. ALB + Target Group

1. **EC2** → `대상 그룹` → `대상 그룹 생성`
   - 유형: **인스턴스**
   - 이름: `wsc2026-analytics-tg`
   - 프로토콜/포트: **HTTP / 5000** ← ⭐ 80 아님
   - VPC: `analytics-vpc`
   - 상태 검사 경로: **`/health`**
   - 다음 → `wsc2026-analytics-ec2` 선택 → `아래에 보류 중인 것으로 포함` → 생성
2. **로드 밸런서** → `로드 밸런서 생성` → **Application Load Balancer**
   - 이름: `wsc2026-analytics-alb`
   - 체계: **인터넷 경계**
   - VPC: `analytics-vpc`, 매핑: **`analytics-pub-a` + `analytics-pub-b`**
   - 보안 그룹: `wsc2026-analytics-alb-sg`
   - 리스너: **HTTP : 80** → 대상 그룹 `wsc2026-analytics-tg`
   - 생성 후 대상 그룹 상태가 **healthy** 될 때까지 대기 (1~2분)

> ✅ 채점 `2-2` 기대값: `80  HTTP` / `wsc2026-analytics-tg  5000`

## 2-9. Managed Apache Flink Studio Notebook

1. **Managed Apache Flink** → `Studio 노트북` → `Studio 노트북 생성`
2. 생성 방식: **빠른 생성 사용**
3. 이름: `wsc2026-analytics-flink`
4. Apache Flink 런타임: **Apache Flink 1.19** (→ `ZEPPELIN-FLINK-3_0`)
5. AWS Glue 데이터베이스: `기본 생성` 또는 새 DB (`default` 사용 가능)
6. `Studio 노트북 생성`
7. 생성된 노트북의 **IAM 역할 이름을 `wsc2026-analytics-flink-role` 로** 만들어 연결
   (빠른 생성이 자동 생성한 역할을 쓰면 이름이 다르다 → IAM 에서 역할을 새로 만들고 노트북 `구성` 에서 교체)
8. 그 역할에 [`files/module2/iam-flink-policy.json`](files/module2/iam-flink-policy.json) 인라인 정책 추가

### SQL 검증

9. 노트북 `실행` → `Apache Zeppelin 에서 열기`
10. [`files/module2/flink-notebook.sql`](files/module2/flink-notebook.sql) 의 셀을 순서대로 실행
11. 다른 창에서 주문 데이터를 흘려보낸다 (CloudShell):

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb \
  --query "LoadBalancers[0].DNSName" --output text)
curl -s -X POST http://$ALB_DNS/orders/generate | jq .
```

12. 두 쿼리가 결과를 뿌리는지 확인.

### 🚨 확인 후 노트북을 반드시 `중지` 한다

```
채점 2-4 기대값:  wsc2026-analytics-flink  READY  ZEPPELIN-FLINK-3_0
```

`READY` = **중지 상태**다. 실행 중이면 `RUNNING` 이 나와서 **오답**이 된다.
쿼리 검증이 끝나면 노트북을 `중지` 시켜 두고 넘어간다.

## 2-10. 검증

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-analytics-alb --query "LoadBalancers[0].DNSName" --output text)

curl -s http://$ALB_DNS/health              # {"status":"healthy"}
curl -s -X POST http://$ALB_DNS/order | jq .  # order_id/product_name/price/quantity/event_time
aws kinesis describe-stream-summary --stream-name wsc2026-order-stream \
  --query "StreamDescriptionSummary.[StreamName,StreamStatus,StreamModeDetails.StreamMode]" --output text
# wsc2026-order-stream  ACTIVE  ON_DEMAND
```

---
---

# 모듈 3. Cloud Event Handling — `eu-west-1` (아일랜드)

CloudTrail → EventBridge → Lambda 자동 복구 + SNS 알림.

> 앞서 말한 대로 **과제지용 4개 + 채점스크립트용 2개 = Lambda 6개** 를 만든다.

## 3-1. VPC

**VPC 생성** → VPC 등

| 항목 | 값 |
|---|---|
| 이름 | `event` |
| CIDR | `172.16.0.0/16` |
| AZ | 2 |
| 퍼블릭 서브넷 | 2 (`172.16.0.0/24`, `172.16.1.0/24`) |
| 프라이빗 서브넷 | **0** |
| NAT | 없음 |

이름 수정: `event-vpc`, `event-pub-a`, `event-pub-b`, `event-pub-rtb`, `event-igw`

## 3-2. Security Group — `wsc2026-event-sg`

- 이름: `wsc2026-event-sg`, VPC: `event-vpc`
- **인바운드 규칙: 0개** ← ⭐ 채점이 `SG Inbound Count (expect 0)` 을 본다
- 아웃바운드: 전체 허용 (또는 443만)

## 3-3. IAM Role — `wsc2026-event-ec2-role`

1. **IAM** → 역할 생성 → **EC2**
2. 권한: `AmazonSSMManagedInstanceCore`
3. 이름: `wsc2026-event-ec2-role`

## 3-4. EC2 — `wsc2026-event-ec2`

| 항목 | 값 |
|---|---|
| 이름 | `wsc2026-event-ec2` |
| AMI | Amazon Linux 2023 |
| 유형 | **t3.micro** |
| 서브넷 | `event-pub-a` |
| 퍼블릭 IP | 활성화 |
| 보안 그룹 | `wsc2026-event-sg` |
| IAM 프로파일 | `wsc2026-event-ec2-role` |
| 태그 | `Name=wsc2026-event-ec2` (+ Config 태그 규칙용 태그 추가, 3-9 참고) |

## 3-5. SNS Topic — `wsc2026-event-alert`

1. **SNS** → `주제 생성` → **표준**
2. 이름: `wsc2026-event-alert` → 생성
3. (선택) 이메일 구독 추가 — 채점에 필수는 아님

ARN 을 메모: `arn:aws:sns:eu-west-1:<ACCOUNT_ID>:wsc2026-event-alert`

## 3-6. CloudTrail — `wsc2026-event-trail`

1. **CloudTrail** → `추적 생성`
2. 이름: `wsc2026-event-trail`
3. S3 버킷: 새로 생성 (기본 이름 그대로)
4. `다음` → 이벤트 유형: **관리 이벤트** 체크
5. API 활동: **읽기 + 쓰기 모두 체크** ← ⭐ 과제지 `Read/Write`
6. 생성

> EventBridge 가 `AWS API Call via CloudTrail` 이벤트를 받으려면 이 추적이 **먼저** 있어야 한다.
> 이벤트가 EventBridge 에 도달하는 데 최대 몇 분 지연이 있으니 모듈 3은 일찍 만들어 둔다.

## 3-7. IAM Role — `wsc2026-event-lambda-role`

1. **IAM** → 역할 생성 → **Lambda**
2. `AWSLambdaBasicExecutionRole` 선택
3. 이름: `wsc2026-event-lambda-role`
4. 인라인 정책으로 [`files/module3/iam-lambda-policy.json`](files/module3/iam-lambda-policy.json) 추가

## 3-8. Lambda 6개 생성

모두 **런타임 Python 3.12**, **핸들러 `index.handler`**, 실행 역할 `wsc2026-event-lambda-role`.
각 함수에서 코드 파일명을 `index.py` 로 바꾸고 `Deploy`.

| 함수 이름 | 코드 | 환경 변수 | 타임아웃 |
|---|---|---|---|
| `wsc2026-sg-remediation` | [`sg_remediation.py`](files/module3/sg_remediation.py) | `SNS_TOPIC_ARN`, `SECURITY_GROUP_ID` | 30초 |
| `wsc2026-role-remediation` | [`role_remediation.py`](files/module3/role_remediation.py) | `SNS_TOPIC_ARN`, `INSTANCE_ID`, `ROLE_NAME=wsc2026-event-ec2-role` | 30초 |
| `wsc2026-ec2-terminate-alert` | [`ec2_terminate_alert.py`](files/module3/ec2_terminate_alert.py) | `SNS_TOPIC_ARN` | 30초 |
| `wsc2026-ec2-type-remediation` | [`ec2_type_remediation.py`](files/module3/ec2_type_remediation.py) | `SNS_TOPIC_ARN`, `INSTANCE_ID`, `INSTANCE_TYPE=t3.micro` | **10분** ⭐ |
| `wsc2026-ec2-stop-remediation` | [`ec2_stop_remediation.py`](files/module3/ec2_stop_remediation.py) | `SNS_TOPIC_ARN` | 30초 |
| `wsc2026-tag-alert` | [`tag_alert.py`](files/module3/tag_alert.py) | `SNS_TOPIC_ARN` | 30초 |

> ⭐ `ec2-type-remediation` 은 인스턴스 **중지 대기(waiter)** 를 하므로 기본 3초 타임아웃이면 무조건 실패한다. 제한 시간을 **10분**으로 올린다.
> `SECURITY_GROUP_ID` / `INSTANCE_ID` 는 3-2, 3-4 에서 만든 실제 ID 를 넣는다.

## 3-9. AWS Config 규칙 2개 (채점스크립트 요구)

1. **AWS Config** → `설정` → `시작하기` (레코더 활성화, 기본 S3 버킷/역할 생성)
2. `규칙` → `규칙 추가` → **AWS 관리형 규칙**

| 규칙 이름 | 관리형 규칙 | 파라미터 |
|---|---|---|
| `wsc2026-sg-ssh-rule` | `restricted-ssh` (INCOMING_SSH_DISABLED) | 기본 |
| `wsc2026-required-tags-rule` | `required-tags` | `tag1Key = Name` |

> ⚠️ 규칙 이름은 관리형 규칙 선택 후 **`이름` 필드를 직접 위 이름으로 바꿔야** 한다.
>
> ✅ 채점 `3-5` 는 `wsc2026-required-tags-rule` 의 **NON_COMPLIANT 리소스가 `None`** 이길 요구한다.
> → 계정 안의 **모든 EC2 인스턴스에 `Name` 태그**가 있어야 한다. 규칙 범위를 `AWS::EC2::Instance` 로 좁히고, eu-west-1 의 EC2 에 Name 태그를 빠짐없이 붙인다.

## 3-10. EventBridge 규칙 6개

**EventBridge** → `규칙` → `규칙 생성` (이벤트 버스: `default`)
각 규칙마다 `사용자 지정 패턴(JSON 편집기)` 을 골라 [`files/module3/event-patterns.json`](files/module3/event-patterns.json) 의 해당 블록을 붙여넣고, 대상으로 Lambda 를 지정한다.

| 규칙 이름 | 감지 대상 | 대상 Lambda |
|---|---|---|
| `wsc2026-sg-change-rule` | `AuthorizeSecurityGroupIngress` | `wsc2026-sg-remediation` |
| `wsc2026-role-change-rule` | `AssociateIamInstanceProfile` | `wsc2026-role-remediation` |
| `wsc2026-ec2-terminate-rule` | State-change → `terminated` | `wsc2026-ec2-terminate-alert` |
| `wsc2026-ec2-type-change-rule` | `ModifyInstanceAttribute` (instanceType) | `wsc2026-ec2-type-remediation` |
| `wsc2026-ec2-stop-rule` | State-change → `stopped` | `wsc2026-ec2-stop-remediation` |
| `wsc2026-tag-rule` | Config Rules Compliance Change | `wsc2026-tag-alert` |

> ⚠️ **`wsc2026-ec2-stop-rule` 과 `wsc2026-ec2-type-change-rule` 은 충돌한다.**
> type-remediation 이 인스턴스를 stop 하면 stop-rule 이 즉시 start 를 걸어 타입 변경이 실패한다.
> 안전한 처리: `ec2_stop_remediation.py` 의 이벤트 패턴에 **type 변경 중이 아닐 때만** 동작하도록 태그를 두거나,
> 실전에서는 **채점 시나리오(stop → 30초 후 running 확인)** 만 통과하면 되므로 **stop-rule 을 살리고**
> type 복구는 `modify_instance_attribute` 실패 시 재시도되게 둔다. 두 시나리오를 따로 테스트할 것.

## 3-11. 검증 (채점 재현)

```bash
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-event-ec2" \
  "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsc2026-event-sg" \
  --query "SecurityGroups[0].GroupId" --output text)

# 위반 발생
aws ec2 stop-instances --instance-ids $INSTANCE_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# 30초 후 자동 복구되었는지
sleep 30
aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text
aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions | length(@)" --output text
```

기대: `running` / `0`

> CloudTrail → EventBridge 전달에 1~4분 걸릴 수 있다. 처음 한 번은 실패해 보일 수 있으니 **여유를 두고 두 번 테스트**한다.
> `sleep 30` 안에 EC2 가 `pending` 이면 부분 감점이니, stop-remediation Lambda 가 **stopped 즉시** start 하도록 되어 있는지 CloudWatch Logs 로 확인.

---
---

# 모듈 4. MSK — `ap-northeast-1` (도쿄)

EC2 Producer → MSK(IAM 인증) → Lambda Consumer → DynamoDB / SNS / S3.

> 🚨 **가장 먼저 시작할 것.** 클러스터 생성에 30~40분이 걸린다.

## 4-1. VPC

**VPC 생성** → VPC 등

| 항목 | 값 |
|---|---|
| 이름 | `msk` |
| CIDR | `192.168.0.0/16` |
| AZ | 2 (**`ap-northeast-1a`, `ap-northeast-1d`**) |
| 퍼블릭 2 / 프라이빗 2 | 아래 표대로 |
| NAT | 1개 AZ 에 |

| Subnet | CIDR | RTB | 인터넷 |
|---|---|---|---|
| `msk-pub-a` | `192.168.0.0/24` | `msk-pub-rtb` | IGW |
| `msk-pub-d` | `192.168.1.0/24` | `msk-pub-rtb` | IGW |
| `msk-priv-a` | `192.168.10.0/24` | `msk-priv-a-rtb` | NAT |
| `msk-priv-d` | `192.168.11.0/24` | `msk-priv-d-rtb` | NAT |

> 도쿄는 `ap-northeast-1b` 가 없는 계정이 많다. 과제지도 **a / d** 를 쓴다.

## 4-2. 보안 그룹

| 이름 | 인바운드 |
|---|---|
| `wsc2026-msk-sg` | TCP **9098** ← `wsc2026-msk-client-sg` (IAM 인증 포트) |
| `wsc2026-msk-client-sg` | 없음 (아웃바운드 전체) |

EC2 와 Lambda 모두 `wsc2026-msk-client-sg` 를 붙인다.

## 4-3. MSK 클러스터 (⭐ 먼저 생성)

1. **Amazon MSK** → `클러스터 생성` → **사용자 지정 생성**
2. 이름: `wsc2026-msk-cluster`, 유형: **프로비저닝됨**
3. Apache Kafka 버전: **3.6.0**
4. 브로커 유형: **kafka.t3.small**
5. AZ 당 브로커 수: **1** → 2 AZ = 총 2 브로커 (replication factor 2 가능)
6. 네트워킹: `msk-vpc`, 서브넷 **`msk-priv-a`, `msk-priv-d`**, 보안 그룹 `wsc2026-msk-sg`
7. 보안 →
   - 액세스 제어: **IAM 역할 기반 인증만 체크** ← ⭐ 다른 인증(비인증/SASL SCRAM/TLS)은 **모두 해제**
   - 퍼블릭 액세스: 끄기
8. 생성 (30~40분 대기 → 그동안 다른 모듈 진행)

> ✅ 채점 `4-3` 기대값: `wsc2026-msk-cluster ACTIVE 3.6.0 kafka.t3.small True`
> 마지막 `True` 가 `ClientAuthentication.Sasl.Iam.Enabled` 다. 비인증 액세스를 같이 켜도 True 는 나오지만,
> "IAM 인증을 통해서만" 요구사항이므로 **비인증은 반드시 끈다.**

## 4-4. DynamoDB + S3

| 리소스 | 값 |
|---|---|
| DynamoDB 테이블 | `wsc2026-sensor-data`, PK `sensorId`(문자열), SK `timestamp`(문자열) |
| S3 버킷 | `wsc2026-sensor-alert-bucket-<비번호>` (도쿄 리전) |
| SNS 주제 | `wsc2026-sensor-alert-topic` (알림용 — Kafka 토픽과 이름 구분) |

## 4-5. IAM Role 2개

### `wsc2026-msk-ec2-role` (EC2)
- 신뢰 주체: EC2
- `AmazonSSMManagedInstanceCore`
- 인라인 정책: [`files/module4/iam-ec2-policy.json`](files/module4/iam-ec2-policy.json)

### `wsc2026-msk-lambda-role` (Lambda)
- 신뢰 주체: Lambda
- `AWSLambdaBasicExecutionRole`
- 인라인 정책: [`files/module4/iam-lambda-policy.json`](files/module4/iam-lambda-policy.json)

> Lambda 가 VPC 안 MSK 를 읽으려면 **ENI 생성 권한(`ec2:CreateNetworkInterface` 등)** 이 필수다. 빠지면 트리거가 `Disabled` 로 떨어진다.

## 4-6. Producer EC2

| 항목 | 값 |
|---|---|
| 이름 | `wsc2026-sensor-producer` |
| AMI | Amazon Linux 2023 |
| 유형 | **t3.small** |
| 서브넷 | `msk-priv-a` (퍼블릭 IP 비활성화) |
| 보안 그룹 | `wsc2026-msk-client-sg` |
| IAM | `wsc2026-msk-ec2-role` |

## 4-7. 부트스트랩 주소 확인 + 토픽 생성

클러스터가 `Active` 가 되면:

```bash
CLUSTER_ARN=$(aws kafka list-clusters --cluster-name-filter wsc2026-msk-cluster \
  --query "ClusterInfoList[0].ClusterArn" --output text)
aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
  --query "BootstrapBrokerStringSaslIam" --output text
```

이 값을 들고 **Session Manager 로 `wsc2026-sensor-producer` 에 접속**해서
[`files/module4/create-topics.sh`](files/module4/create-topics.sh) 를 실행한다 (`BOOTSTRAP` 만 바꿔서).

| Topic | Partitions | Replication Factor |
|---|:-:|:-:|
| `wsc2026-sensor-raw` | 3 | 2 |
| `wsc2026-sensor-alert` | 1 | 2 |

## 4-8. Producer 실행 (systemd)

`app` (Go 바이너리) 을 EC2 `/opt/app/app` 으로 올린 뒤:

```bash
chmod +x /opt/app/app
cat >/etc/systemd/system/producer.service <<'EOF'
<files/module4/producer.service 내용, BOOTSTRAP_SERVERS 치환>
EOF

systemctl daemon-reload
systemctl enable --now producer
journalctl -u producer -f   # SENSOR-001: temp=... 로그 확인
```

> 바이너리 전송: 임시 S3 버킷에 올려두고 `aws s3 cp` 로 받는 게 가장 빠르다.

## 4-9. Consumer Lambda 2개

### Lambda Layer 준비 (`wsc2026-sensor-consumer` 전용)

`sensor_consumer.py` 는 alert 토픽으로 재발행하기 위해 `kafka-python` + `aws-msk-iam-sasl-signer` 가 필요하다.
CloudShell(도쿄)에서:

```bash
mkdir -p layer/python && cd layer
pip install kafka-python-ng aws-msk-iam-sasl-signer-python -t python/
zip -qr msk-layer.zip python
aws lambda publish-layer-version --layer-name wsc2026-msk-layer \
  --zip-file fileb://msk-layer.zip --compatible-runtimes python3.14
```

### 함수 생성

| 함수 | 코드 | 런타임 | 환경 변수 |
|---|---|---|---|
| `wsc2026-sensor-consumer` | [`sensor_consumer.py`](files/module4/sensor_consumer.py) | **Python 3.14** | `DDB_TABLE=wsc2026-sensor-data`<br>`ALERT_TOPIC=wsc2026-sensor-alert`<br>`BOOTSTRAP_SERVER=<IAM 부트스트랩>` |
| `wsc2026-sensor-alert-consumer` | [`sensor_alert_consumer.py`](files/module4/sensor_alert_consumer.py) | **Python 3.14** | `SNS_TOPIC_ARN=<sensor-alert-topic ARN>`<br>`S3_BUCKET=wsc2026-sensor-alert-bucket-<비번호>` |

공통 설정:
- 핸들러 `index.handler`, 실행 역할 `wsc2026-msk-lambda-role`
- `구성` → `VPC`: `msk-vpc`, 서브넷 `msk-priv-a` + `msk-priv-d`, SG `wsc2026-msk-client-sg`
- 제한 시간 1분 이상
- `sensor-consumer` 에만 위 Layer 첨부

> ✅ 채점 `4-2` 는 런타임이 정확히 `python3.14` 여야 한다.

## 4-10. MSK 트리거 연결

각 함수 → `트리거 추가` → **MSK**

| 함수 | 클러스터 | 토픽 | 배치 크기 |
|---|---|---|---|
| `wsc2026-sensor-consumer` | `wsc2026-msk-cluster` | `wsc2026-sensor-raw` | 10 |
| `wsc2026-sensor-alert-consumer` | `wsc2026-msk-cluster` | `wsc2026-sensor-alert` | 10 |

인증: **IAM 역할 기반 인증** / 시작 위치: `TRIM_HORIZON` 또는 `LATEST` / `트리거 활성화` 체크

> ✅ 채점 `4-4` 기대값: 두 함수 모두 event source mapping `State = Enabled`.
> `Creating` 에서 멈추면 Lambda 의 VPC/SG/IAM(ENI 권한, `kafka-cluster:*`) 을 다시 본다. 활성화까지 수 분 걸린다.

## 4-11. 검증

```bash
# 4-5-A : 항목 형식
aws dynamodb scan --table-name wsc2026-sensor-data --max-items 1 \
  --query "Items[0].{sensorId:sensorId.S,temperature:temperature.S,status:status.S}" --output json
# { "sensorId": "SENSOR-002", "temperature": "64.6", "status": "NORMAL" }

# 4-5-B : timestamp 형식
aws dynamodb scan --table-name wsc2026-sensor-data --max-items 3 \
  --query "Items[*].{sensorId:sensorId.S,timestamp:timestamp.S}" --output table
# timestamp 는 2026-06-01T18:28:24+09:00 형태 (ISO8601 KST)
```

> ⭐ 채점이 `temperature.S` / `status.S` 로 읽는다. **temperature 를 Number 로 저장하면 `null` 이 나와 오답**이다.
> `sensor_consumer.py` 가 `str(...)` 로 넣는 이유. `timestamp` 는 Producer 가 주는 값을 **가공 없이** 그대로 저장한다.

---
---

# ✅ 최종 점검 — 채점 스크립트 그대로 돌려보기

각 리전 CloudShell 에서 순서대로 실행한다.

```bash
# 싱가포르
aws configure set region ap-southeast-1 && bash mark2-1.sh
# 서울
aws configure set region ap-northeast-2 && bash mark2-2.sh
# 아일랜드  (⚠️ EC2 를 stop 시키고 SG 를 뚫는다. 실행 후 상태 원복 확인)
aws configure set region eu-west-1      && bash mark2-3.sh
# 도쿄
aws configure set region ap-northeast-1 && bash mark2-4.sh
```

## 종료 전 마지막 체크리스트

- [ ] 모듈 1: `error/` 에 JSON 4개만 (재실행으로 8개 쌓이지 않았는지)
- [ ] 모듈 1: `processed/test.csv` 존재, `input/` 비어 있음
- [ ] 모듈 2: `systemctl is-active app` → `active`, `is-enabled` → `enabled`
- [ ] 모듈 2: **Flink 노트북 `READY`(중지)**
- [ ] 모듈 2: ALB 대상 그룹 `healthy`
- [ ] 모듈 3: EC2 `running`, SG 인바운드 0개
- [ ] 모듈 3: Config 규칙 2개 `ACTIVE`, required-tags NON_COMPLIANT 없음
- [ ] 모듈 4: MSK `ACTIVE`, 트리거 2개 `Enabled`
- [ ] 모듈 4: Producer `active`, DynamoDB 에 데이터 유입 중
- [ ] **부하/테스트 스크립트 전부 중지** (과제지 유의사항 8번)
- [ ] Bastion EC2 가 모든 리소스에 접근 가능한지 (유의사항 10번)

---

## 📌 자주 놓치는 함정 모음

| # | 함정 |
|:-:|---|
| 1 | **리전 4개가 전부 다르다.** 콘솔 리전 확인 습관화 |
| 2 | Flink 노트북은 **중지(READY)** 상태여야 채점 통과 |
| 3 | Target Group 포트는 **5000**, 리스너는 **80** |
| 4 | systemd 서비스 이름은 반드시 **`app`** |
| 5 | IAM 역할 이름 오타 `wsc2026-alaytics-ec2-role` (과제지 그대로) |
| 6 | 서브넷 **Name 태그**로 채점한다 (`analytics-priv-a`) |
| 7 | `ec2-type-remediation` Lambda 타임아웃 **10분** |
| 8 | DynamoDB `temperature`/`status` 는 **String** |
| 9 | MSK는 **IAM 인증만** 켜기 (비인증 해제) |
| 10 | Lambda VPC 접근 → **ENI 생성 IAM 권한** 필요 |
| 11 | 모듈 1 `error/` 폴더는 재실행 전에 **비우기** |
| 12 | 모듈 3은 **과제지 이름 + 채점스크립트 이름 둘 다** 만들기 |
