# ☁️ 2026 클라우드컴퓨팅 **제2과제** — AWS 콘솔 수동 구축 (처음부터 끝까지)

> 기준: **과제지_v3 / 채점기준표_v3** · 과제명 **Small Challenge** · 경기시간 4시간 · 총 **30점**
> `<...>` 표기는 **변수** → 본인 값(계정 ID·비번호·엔드포인트 등)으로 치환.
> 리전이 **모듈마다 다릅니다.** 각 모듈 시작 시 콘솔 우측 상단 리전을 **반드시** 먼저 바꾸세요.

| 모듈 | 주제 | 리전 | 배점 |
|:---:|------|------|:---:|
| **1** | REST API (DynamoDB + Lambda + API Gateway) | **ap-northeast-2 (서울)** | 7.5 |
| **2** | RDS Connection (VPC + RDS + Proxy + Lambda) | **ap-northeast-1 (도쿄)** | 8.0 |
| **3** | Workflow (S3 + EventBridge + SFN + Lambda + DynamoDB) | **us-east-1 (버지니아 북부)** | 9.0 |
| **4** | VPN (VPC + EC2 + Client VPN) | **ap-southeast-1 (싱가포르)** | 5.5 |

---

## 📑 진행 체크리스트

작업하면서 `[ ]` → `[x]` 로 바꿔가며 진행하세요. **모듈 순서대로 채점**됩니다.

**모듈 1 — REST API (서울)**
- [ ] 1-1. DynamoDB `wsc2026-api-storage` (PK=id, 온디맨드, 삭제방지)
- [ ] 1-2. IAM 역할 + Lambda `wsc2026-api-handler` (python3.14)
- [ ] 1-3. API Gateway `wsc2026-rest-api` (POST·GET → V1 배포)

**모듈 2 — RDS Connection (도쿄)**
- [ ] 2-1. VPC `wsc2026-db-vpc` + 서브넷 4개
- [ ] 2-2. RDS MySQL 8.4.9 `wsc2026-rds-instance`
- [ ] 2-3. Secrets Manager + RDS Proxy `wsc2026-rds-proxy`
- [ ] 2-4. Lambda `wsc2026-db-client` (pymysql 계층 + VPC)

**모듈 3 — Workflow (버지니아)**
- [ ] 3-1. DynamoDB `wsc2026-target-db`
- [ ] 3-2. S3 `wsc2026-wf-inbound-bucket` (EventBridge 알림 ON)
- [ ] 3-3. Lambda `wsc2026-transform-lambda`
- [ ] 3-4. Step Functions `wsc2026-wf-statemachine`
- [ ] 3-5. EventBridge 규칙 `wsc2026-s3-trigger-rule`

**모듈 4 — VPN (싱가포르)**
- [ ] 4-1. VPC `wsc2026-vpn-vpc` + 서브넷 4개 (pub→IGW / vpn→NAT)
- [ ] 4-2. EC2 `vpn-ec2` (al2023, t3.micro, vpn-sn-b)
- [ ] 4-3. 인증서 발급 + ACM 등록 (`cve.wsc`, `client.wsc`)
- [ ] 4-4. Client VPN `wsc-vpn` + 연결 테스트

### 🎯 채점 배점 한눈에

| # | 항목 | 배점 | 이 문서 |
|---|------|:---:|:---:|
| 1 | DynamoDB (Table, Billing) | 2.5 | 1-1 |
| 2 | Lambda (Name/Runtime, Policy, GET Test) | 2.5 | 1-2 |
| 3 | API Gateway (Name, Method/Stage, POST Test) | 2.5 | 1-3 |
| 4 | VPC (VPC, Subnet) | 1.5 | 2-1 |
| 5 | RDS (Name/Status, Proxy, Class/Ver/Engine) | 2.5 | 2-2·2-3 |
| 6 | Lambda (Name, Runtime, Read Test) | 4.0 | 2-4 |
| 7 | S3 (Bucket, EventBridge Alarm) | 1.5 | 3-2 |
| 8 | EventBridge (Rule) | 1.5 | 3-5 |
| 9 | Lambda (Name, Test) | 3.0 | 3-3 |
| 10 | DynamoDB (Name, Billing) | 1.5 | 3-1 |
| 11 | Step Function (Test) | 1.5 | 3-4 |
| 12 | VPC (VPC, Subnet) | 1.5 | 4-1 |
| 13 | EC2 (Name, Type) | 1.5 | 4-2 |
| 14 | VPN (Certificate, Connect Test) | 2.5 | 4-3·4-4 |

> 💡 **CloudShell** = 콘솔 상단 터미널 아이콘(`>_`). aws CLI·python·zip 이 설치돼 있고 자격증명 자동.
> CloudShell 도 **현재 콘솔 리전**을 따라갑니다. 모듈마다 리전을 바꾸면 CloudShell 도 새로 열거나 `--region` 을 명시하세요.
> 📁 이 폴더 `files/` 안에 **Lambda 소스·정책 JSON** 이 모듈별로 들어 있습니다. 그대로 업로드/복붙하세요.

---

# 🟦 모듈 1 — REST API `서울(ap-northeast-2)`

> 흐름: 클라이언트 → **API Gateway** (POST/GET `/items`) → **Lambda** → **DynamoDB**

## 1-1. 🗄️ DynamoDB 테이블 `wsc2026-api-storage`

**콘솔 경로:** `DynamoDB → 테이블 → 테이블 생성`

| 항목 | 값 |
|------|-----|
| 테이블 이름 | `wsc2026-api-storage` |
| 파티션 키(PK) | `id` (문자열, String) |
| 정렬 키 | 없음 |
| 설정 | **설정 사용자 지정** |
| 용량 모드 | **온디맨드 (On-demand)** ← 과금 최소화 |

→ 생성 후 테이블 선택 → `추가 설정(작업) → 삭제 방지 켜기` **활성화** (과제지: "삭제되지 않도록 구성").

**✅ 확인 (채점 1-1 / 1-2):**
```bash
aws dynamodb describe-table --table-name wsc2026-api-storage \
  --query "Table.TableName" --output text
# → wsc2026-api-storage
aws dynamodb describe-table --table-name wsc2026-api-storage \
  --query "Table.BillingModeSummary.BillingMode" --output text
# → PAY_PER_REQUEST
```

## 1-2. 🔧 Lambda `wsc2026-api-handler`

### (a) IAM 역할 — DynamoDB 읽기/쓰기 **최소권한**

**콘솔 경로:** `IAM → 역할 → 역할 생성`
1. 신뢰 개체 = **AWS 서비스 → Lambda**
2. 권한은 일단 건너뛰고 생성 → 역할 이름 `wsc2026-api-handler-role`
3. 생성한 역할 → `권한 추가 → 인라인 정책 생성 → JSON` 에 아래 붙여넣기
   (`files/module1/lambda-dynamodb-policy.json`, `<ACCOUNT_ID>` 치환)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:GetItem"],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/wsc2026-api-storage" },
    { "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:*" }
  ]
}
```
> ⚠️ 채점 2-2 는 정책 Action 에 **`dynamodb:PutItem`, `dynamodb:GetItem`** 만 있는지 확인합니다. `dynamodb:*` 나 관리형 `AmazonDynamoDBFullAccess` 를 붙이면 **감점**. 위 두 액션만 사용하세요.

### (b) 함수 생성

**콘솔 경로:** `Lambda → 함수 → 함수 생성 → 새로 작성`

| 항목 | 값 |
|------|-----|
| 함수 이름 | `wsc2026-api-handler` |
| 런타임 | **Python 3.14** |
| 아키텍처 | x86_64 |
| 실행 역할 | **기존 역할 사용** → `wsc2026-api-handler-role` |

→ 생성 후:
1. **코드** 탭 → `files/module1/handler.py` 내용을 붙여넣고 **Deploy**
2. **런타임 설정 → 핸들러**를 `handler.handler` 로 변경
3. **구성 → 환경 변수** → `TABLE_NAME = wsc2026-api-storage` 추가

> 📝 `handler.py` 는 API Gateway 호출(`httpMethod`)과 직접 invoke(`method`) 를 **모두** 처리합니다. 채점 2-3 은 직접 invoke 로 raw item 을 기대하므로 이 코드를 그대로 쓰세요.

**✅ 확인 (채점 2-1 / 2-3):**
```bash
aws lambda get-function --function-name wsc2026-api-handler \
  --query "Configuration.FunctionName" --output text          # → wsc2026-api-handler
aws lambda get-function-configuration --function-name wsc2026-api-handler \
  --query "Runtime" --output text                              # → python3.14

# GET 직접 호출 테스트 (먼저 해당 id 를 넣어 둔 뒤 확인)
aws lambda invoke --function-name wsc2026-api-handler \
  --payload '{"method":"POST","id":"lambda-chk-999","name":"Check-Post","team":"DevOps"}' \
  --cli-binary-format raw-in-base64-out /dev/null >/dev/null
aws lambda invoke --function-name wsc2026-api-handler \
  --payload '{"method": "GET", "id": "lambda-chk-999"}' \
  --cli-binary-format raw-in-base64-out out_l_get.json >/dev/null && cat out_l_get.json && echo ""
# → {"id": "lambda-chk-999", "name": "Check-Post", "team": "DevOps"}
```
> 💡 채점표 2-3 은 GET 만 실행하므로, 위처럼 **먼저 POST 로 한 번 저장**해 두면 안전합니다.

## 1-3. 🌐 API Gateway `wsc2026-rest-api`

**콘솔 경로:** `API Gateway → API 생성 → REST API(비공개 아님) → 구축`

| 항목 | 값 |
|------|-----|
| API 이름 | `wsc2026-rest-api` |
| API 유형 | **REST API** (HTTP API 아님) |
| 엔드포인트 유형 | 지역(Regional) |

### (a) 리소스 & 메서드
1. `리소스 → 리소스 생성` → 리소스 이름 **`items`** (경로 `/items`)
2. `/items` 선택 → `메서드 생성` → **POST**
   - 통합 유형 = **Lambda 함수**
   - **Lambda 프록시 통합 사용** ✅ 체크
   - Lambda 함수 = `wsc2026-api-handler`
3. 동일하게 **GET** 메서드도 생성 (프록시 통합 ✅)

> Lambda 프록시 통합을 켜면 `wsc2026-api-handler` 에 **호출 권한이 자동 부여**됩니다(리소스 기반 정책).

### (b) 배포 — 스테이지 이름 **V1**
`API 배포` → 스테이지 = **[새 스테이지]** → 스테이지 이름 **`V1`** (대문자 주의)

**✅ 확인 (채점 3-1 / 3-2 / 3-3):**
```bash
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='wsc2026-rest-api'].id" --output text)
echo "API_ID: $API_ID"

aws apigateway get-resources --rest-api-id "$API_ID" \
  --query "items[?path=='/items'].resourceMethods" --output json    # → "GET": {}, "POST": {}
aws apigateway get-stages --rest-api-id "$API_ID" \
  --query "items[*].stageName" --output text                        # → V1

# POST 실제 호출 테스트
URL="https://${API_ID}.execute-api.ap-northeast-2.amazonaws.com/V1/items"
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"id": "api-chk-888", "name": "Check-Api", "team": "Cloud"}' "$URL" && echo ""
# → {"message": "Item created successfully", "id": "api-chk-888"}
```

---

# 🟩 모듈 2 — RDS Connection `도쿄(ap-northeast-1)`

> ⚠️ **리전을 도쿄로 변경!** 흐름: Lambda(VPC 내부) → **RDS Proxy** → **RDS MySQL** (자격증명은 Secrets Manager)

## 2-1. 🌐 VPC `wsc2026-db-vpc` + 서브넷 4개

**콘솔 경로:** `VPC → VPC 생성 → "VPC 등" 대신 "VPC만"` 권장 (하나씩 통제)

### (a) VPC
| 항목 | 값 |
|------|-----|
| 이름 태그 | `wsc2026-db-vpc` |
| IPv4 CIDR | `10.0.0.0/16` |
| DNS 호스트 이름 | **활성화** (생성 후 작업 → VPC 설정 편집) |

### (b) 서브넷 4개 (`VPC → 서브넷 → 서브넷 생성`, VPC=wsc2026-db-vpc)
| 이름 | 가용영역(AZ) | CIDR | 용도 |
|------|:--:|------|------|
| `wsc2026-db-sn-a` | ap-northeast-1**a** | `10.0.1.0/24` | 프라이빗(RDS) |
| `wsc2026-db-sn-c` | ap-northeast-1**c** | `10.0.2.0/24` | 프라이빗(RDS) |
| `wsc2026-pub-sn-a` | ap-northeast-1**a** | `10.0.3.0/24` | 퍼블릭 |
| `wsc2026-pub-sn-c` | ap-northeast-1**c** | `10.0.4.0/24` | 퍼블릭 |

> RDS 서브넷 그룹은 **2개 AZ 이상**을 요구하므로 db-sn-a(1a)·db-sn-c(1c) 로 AZ 를 나눕니다.
> pub 서브넷은 IGW·라우팅이 필수는 아니지만(채점은 이름/CIDR 만 확인), 만들어 두면 됩니다.

**✅ 확인 (채점 4-1):**
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-db-vpc" \
  --query "Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}" --output table --region ap-northeast-1
aws ec2 describe-subnets --filters \
  "Name=tag:Name,Values=wsc2026-db-sn-a,wsc2026-db-sn-c,wsc2026-pub-sn-a,wsc2026-pub-sn-c" \
  --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone}" \
  --output table --region ap-northeast-1
```

## 2-2. 🛢️ RDS MySQL `wsc2026-rds-instance`

먼저 **보안 그룹**과 **서브넷 그룹**을 만듭니다.

**보안 그룹** (`VPC → 보안 그룹 → 생성`)
| 이름 | VPC | 인바운드 | 아웃바운드 |
|------|-----|----------|-----------|
| `wsc2026-rds-sg` | wsc2026-db-vpc | TCP **3306** ← `10.0.0.0/16` | 전체 허용 |
| `wsc2026-lambda-sg` | wsc2026-db-vpc | (없음) | 전체 허용 |

**RDS 서브넷 그룹** (`RDS → 서브넷 그룹 → 생성`)
| 항목 | 값 |
|------|-----|
| 이름 | `wsc2026-db-subnet-group` |
| VPC | wsc2026-db-vpc |
| 서브넷 | **`wsc2026-db-sn-a`, `wsc2026-db-sn-c`** (프라이빗 2개) |

**DB 인스턴스** (`RDS → 데이터베이스 생성`)
| 항목 | 값 |
|------|-----|
| 생성 방식 | 표준 생성 |
| 엔진 | **MySQL** |
| 엔진 버전 | **8.4.9** |
| 템플릿 | **샌드박스(개발/테스트)** ← 비용 절약 |
| DB 식별자 | `wsc2026-rds-instance` |
| 마스터 사용자 | `admin` |
| 마스터 암호 | `Wsc2026Admin!` (직접 지정 — Proxy·Secret 과 동일해야 함) |
| 인스턴스 클래스 | **db.t3.micro** |
| 스토리지 | 20 GiB (gp3 기본) |
| VPC | wsc2026-db-vpc |
| DB 서브넷 그룹 | `wsc2026-db-subnet-group` |
| **퍼블릭 액세스** | **아니요(No)** ← 외부 완전 차단 |
| 보안 그룹 | `wsc2026-rds-sg` |
| 추가 구성 → 초기 DB 이름 | `data` (선택, Lambda 가 없으면 자동 생성) |

> ⏱️ RDS 생성은 수 분~10분 걸립니다. 상태 `사용 가능(available)` 이 될 때까지 다음 단계(Secret/Proxy)를 병행해도 됩니다.

**✅ 확인 (채점 5-1 / 5-3):**
```bash
aws rds describe-db-instances --db-instance-identifier wsc2026-rds-instance \
  --query "DBInstances[0].DBInstanceStatus" --output text --region ap-northeast-1   # → available
aws rds describe-db-instances --db-instance-identifier wsc2026-rds-instance \
  --query "DBInstances[0].{Class:DBInstanceClass,Engine:Engine,Version:EngineVersion,PublicAccess:PubliclyAccessible}" \
  --output table --region ap-northeast-1
# → db.t3.micro / mysql / 8.4.9 / False
```

## 2-3. 🔑 Secrets Manager + RDS Proxy `wsc2026-rds-proxy`

### (a) Secrets Manager — DB 자격증명 보관
**콘솔 경로:** `Secrets Manager → 새 보안 암호 저장 → Amazon RDS 데이터베이스에 대한 자격 증명`
| 항목 | 값 |
|------|-----|
| 사용자 이름 | `admin` |
| 암호 | `Wsc2026Admin!` |
| 데이터베이스 | `wsc2026-rds-instance` 선택 |
| 보안 암호 이름 | `wsc2026-rds-secret` |

### (b) RDS Proxy
**콘솔 경로:** `RDS → 프록시 → 프록시 생성`
| 항목 | 값 |
|------|-----|
| 프록시 식별자 | `wsc2026-rds-proxy` |
| 엔진 호환성 | MySQL |
| 유휴 클라이언트 연결 제한 시간 | 기본 |
| **연결 풀 최대치** | 기본(대규모 커넥션 풀링) |
| 대상 DB | `wsc2026-rds-instance` |
| Secrets Manager 보안 암호 | `wsc2026-rds-secret` |
| IAM 역할 | **새 역할 생성** (Secret 읽기 권한 자동) |
| 서브넷 | `wsc2026-db-sn-a`, `wsc2026-db-sn-c` |
| 보안 그룹 | `wsc2026-rds-sg` |
| TLS 요구 | 끄기(선택) |

**✅ 확인 (채점 5-2):**
```bash
aws rds describe-db-proxies --db-proxy-name wsc2026-rds-proxy \
  --query "DBProxies[0].{Name:DBProxyName,Status:Status,Endpoint:Endpoint}" \
  --output table --region ap-northeast-1
# → wsc2026-rds-proxy / available / ...proxy-xxxx.ap-northeast-1.rds.amazonaws.com
```
> 📝 출력된 **Endpoint** 를 메모 → 2-4 Lambda 의 `DB_HOST` 환경변수에 사용.

## 2-4. 🔧 Lambda `wsc2026-db-client` (pymysql 계층)

MySQL 접속에는 `pymysql` 라이브러리가 필요 → **Lambda 계층**으로 추가합니다.

### (a) pymysql 계층 빌드 (CloudShell, 도쿄 리전)
```bash
cd /tmp && rm -rf layer && mkdir -p layer/python
pip3 install pymysql -t layer/python --quiet
cd layer && zip -r ../pymysql-layer.zip python >/dev/null && cd ..
aws lambda publish-layer-version --layer-name pymysql \
  --zip-file fileb://pymysql-layer.zip \
  --compatible-runtimes python3.14 --region ap-northeast-1
```

### (b) IAM 역할
`IAM → 역할 생성 → Lambda` → 이름 `wsc2026-db-client-role`
→ 관리형 정책 **`AWSLambdaVPCAccessExecutionRole`** 연결 (VPC ENI 생성 권한).

### (c) 함수 생성 (`Lambda → 함수 생성`)
| 항목 | 값 |
|------|-----|
| 함수 이름 | `wsc2026-db-client` |
| 런타임 | **Python 3.14** |
| 실행 역할 | `wsc2026-db-client-role` |

→ 생성 후:
1. **코드** 탭 → `files/module2/db_client.py` 붙여넣고 **Deploy** → 핸들러 `db_client.lambda_handler`
2. **구성 → 계층 → 계층 추가** → 사용자 지정 계층 `pymysql` 선택
3. **구성 → VPC** → VPC=`wsc2026-db-vpc`, 서브넷=`db-sn-a`·`db-sn-c`, 보안그룹=`wsc2026-lambda-sg`
4. **구성 → 환경 변수**:
   | 키 | 값 |
   |----|-----|
   | `DB_HOST` | *(2-3 에서 메모한 프록시 엔드포인트)* |
   | `DB_USER` | `admin` |
   | `DB_PASSWORD` | `Wsc2026Admin!` |
5. **구성 → 일반 구성 → 제한 시간**을 **30초** 로 늘림 (스키마 생성 여유)

**✅ 확인 (채점 6-1 / 6-2 / 6-3):**
```bash
aws lambda get-function --function-name wsc2026-db-client \
  --query "Configuration.{FunctionName:FunctionName,State:State}" --output table --region ap-northeast-1
aws lambda get-function-configuration --function-name wsc2026-db-client \
  --query "{Runtime:Runtime,State:State}" --output table --region ap-northeast-1   # → python3.14 / Active

# create 로 한 건 넣고 read 로 확인
aws lambda invoke --function-name wsc2026-db-client \
  --payload '{"action":"create","username":"test_user","role":"viewer"}' \
  --cli-binary-format raw-in-base64-out /tmp/c.json --region ap-northeast-1 && cat /tmp/c.json; echo ""
aws lambda invoke --function-name wsc2026-db-client \
  --payload '{"action":"read","username":"test_user"}' \
  --cli-binary-format raw-in-base64-out /tmp/out.json --region ap-northeast-1 && cat /tmp/out.json
# → {"statusCode": 200, "body": "{\"username\": \"test_user\", \"role\": \"viewer\", \"created_at\": \"...\"}"}
```
> 🐛 `read` 결과가 `null` 이면 위처럼 **먼저 `create`** 를 실행하세요. 타임아웃/연결 오류면 Lambda 서브넷·SG·Proxy 상태(available)를 재확인.

---

# 🟨 모듈 3 — Workflow `버지니아 북부(us-east-1)`

> ⚠️ **리전을 us-east-1 로 변경!**
> 흐름: **S3** 업로드 → **EventBridge** 규칙 → **Step Functions** → **Lambda(transform)** → **DynamoDB**

## 3-1. 🗄️ DynamoDB `wsc2026-target-db`
`DynamoDB → 테이블 생성`
| 항목 | 값 |
|------|-----|
| 이름 | `wsc2026-target-db` |
| 파티션 키 | `id` (문자열) |
| 용량 모드 | **온디맨드** |

**✅ 확인 (채점 10-1):**
```bash
aws dynamodb describe-table --table-name wsc2026-target-db --region us-east-1 | grep TableName
aws dynamodb describe-table --table-name wsc2026-target-db --region us-east-1 | grep BillingMode
# → "TableName": "wsc2026-target-db" / "BillingMode": "PAY_PER_REQUEST"
```

## 3-2. 🪣 S3 `wsc2026-wf-inbound-bucket` (EventBridge 알림)
`S3 → 버킷 만들기`
| 항목 | 값 |
|------|-----|
| 이름 | `wsc2026-wf-inbound-bucket` (전역 고유) |
| 리전 | 미국 동부(버지니아 북부) us-east-1 |

→ 생성 후: 버킷 선택 → **속성 → Amazon EventBridge → 편집 → "이 버킷의 모든 이벤트에 대해 Amazon EventBridge로 알림 보내기" 켜기(On)**.

**✅ 확인 (채점 7-1):**
```bash
aws s3api head-bucket --bucket wsc2026-wf-inbound-bucket
aws s3api get-bucket-notification-configuration --bucket wsc2026-wf-inbound-bucket | grep -i eventbridge
# → "EventBridgeConfiguration": {}
```

## 3-3. 🔧 Lambda `wsc2026-transform-lambda`
### (a) IAM 역할
`IAM → 역할 생성 → Lambda` → 이름 `wsc2026-transform-lambda-role`
→ 인라인 정책(JSON) = `files/module3/transform-lambda-policy.json` (S3 GetObject + Logs).

### (b) 함수
| 항목 | 값 |
|------|-----|
| 함수 이름 | `wsc2026-transform-lambda` |
| 런타임 | **Python 3.14** |
| 실행 역할 | `wsc2026-transform-lambda-role` |
| 제한 시간 | 30초 |

→ 코드 = `files/module3/transform.py`, 핸들러 `transform.lambda_handler`, **Deploy**.

> 📝 이 함수는 S3 객체를 읽어 `id`·`data` 검증 → 없으면 `ValidationError`, null 이면 `TransformError`(Custom Error)를 raise 합니다. 정상이면 `status:"processed"`, `processed_at` 추가.

**✅ 확인 (채점 9-1 / 9-2):** — 먼저 테스트 객체를 올려 둔다
```bash
echo '{"id": "abc123", "data": "sample_value"}' > /tmp/test.json
aws s3 cp /tmp/test.json s3://wsc2026-wf-inbound-bucket/test.json --region us-east-1

aws lambda get-function-configuration --function-name wsc2026-transform-lambda --region us-east-1 \
  | grep -E "FunctionName|Runtime"
aws lambda invoke --function-name wsc2026-transform-lambda \
  --payload '{"detail":{"bucket":{"name":"wsc2026-wf-inbound-bucket"},"object":{"key":"test.json"}}}' \
  --cli-binary-format raw-in-base64-out response_normal.json --region us-east-1 && cat response_normal.json
# → {"statusCode": 200, "body": {"id": "abc123", "data": "sample_value", "status": "processed", "processed_at": "..."}}
```

## 3-4. 🔀 Step Functions `wsc2026-wf-statemachine`
### (a) 실행 역할
`IAM → 역할 생성` → 신뢰 개체 = **Step Functions** → 이름 `wsc2026-sfn-role`
→ 인라인 정책 = `files/module3/stepfunctions-policy.json` (`lambda:InvokeFunction` + `dynamodb:PutItem`, `<ACCOUNT_ID>` 치환).

### (b) 상태 머신
`Step Functions → 상태 머신 생성 → 처음부터 만들기(코드로 작성)` → 유형 **표준(Standard)**
→ 정의(코드) 창에 `files/module3/workflow.asl.json` 붙여넣기
| 항목 | 값 |
|------|-----|
| 이름 | `wsc2026-wf-statemachine` |
| 실행 역할 | **기존 역할** `wsc2026-sfn-role` |

> 정의 요약: `TransformData`(Lambda invoke) → 성공 시 `SaveToDynamoDB`(PutItem), `ValidationError`/`TransformError` catch 시 `HandleError`(Fail).

## 3-5. 📢 EventBridge 규칙 `wsc2026-s3-trigger-rule`
`Amazon EventBridge → 규칙 → 규칙 생성` (기본 이벤트 버스, us-east-1)
| 항목 | 값 |
|------|-----|
| 이름 | `wsc2026-s3-trigger-rule` |
| 규칙 유형 | 이벤트 패턴이 있는 규칙 |
| 이벤트 패턴(사용자 지정 JSON) | `files/module3/s3-event-pattern.json` ↓ |

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": { "bucket": { "name": ["wsc2026-wf-inbound-bucket"] } }
}
```
| 대상 | Step Functions 상태 머신 → `wsc2026-wf-statemachine` |
| 실행 역할 | 새 역할 생성(EventBridge → StartExecution) |

**✅ 확인 (채점 8-1):**
```bash
aws events describe-rule --name wsc2026-s3-trigger-rule --region us-east-1
# → "Name": "wsc2026-s3-trigger-rule", ... "State": "ENABLED"
```

**✅ 전체 워크플로우 테스트 (채점 11-1):**
```bash
echo '{"id":"abc123","data":"sample_value"}' > test.json
aws s3 cp test.json s3://wsc2026-wf-inbound-bucket/test.json --region us-east-1
sleep 5
aws stepfunctions list-executions --region us-east-1 \
  --state-machine-arn $(aws stepfunctions list-state-machines --region us-east-1 \
    --query "stateMachines[0].stateMachineArn" --output text) \
  --query "executions[0].{status:status,name:name}"
aws dynamodb get-item --table-name wsc2026-target-db --key '{"id":{"S":"abc123"}}' --region us-east-1
# → status: SUCCEEDED, DynamoDB 에 id/data/status/processed_at 저장됨
```

---

# 🟥 모듈 4 — VPN `싱가포르(ap-southeast-1)`

> ⚠️ **리전을 ap-southeast-1 로 변경!**
> 흐름: 사용자 PC → **Client VPN(상호 인증)** → 프라이빗 서브넷의 **EC2** 로 SSH 접속

## 4-1. 🌐 VPC `wsc2026-vpn-vpc` + 서브넷 4개
### (a) VPC — 이름 `wsc2026-vpn-vpc`, CIDR `10.0.0.0/16`, DNS 호스트이름 활성화

### (b) 서브넷 4개
| 이름 | AZ | CIDR | 연결 |
|------|:--:|------|------|
| `wsc2026-pub-sn-a` | ap-southeast-1**a** | `10.0.1.0/24` | IGW (퍼블릭 IP 자동할당 ON) |
| `wsc2026-pub-sn-b` | ap-southeast-1**b** | `10.0.2.0/24` | IGW (퍼블릭 IP 자동할당 ON) |
| `wsc2026-vpn-sn-a` | ap-southeast-1**a** | `10.0.3.0/24` | NAT |
| `wsc2026-vpn-sn-b` | ap-southeast-1**b** | `10.0.4.0/24` | NAT |

### (c) 게이트웨이 & 라우팅
1. **IGW** `wsc2026-vpn-igw` 생성 → VPC 에 연결
2. **NAT 게이트웨이** `wsc2026-vpn-nat` → 서브넷 `wsc2026-pub-sn-a`, **새 EIP 할당**
3. 라우팅 테이블 2개:
   | 이름 | 경로 | 연결 서브넷 |
   |------|------|-------------|
   | `wsc2026-pub-rt` | `0.0.0.0/0 → wsc2026-vpn-igw` | pub-sn-a, pub-sn-b |
   | `wsc2026-vpn-rt` | `0.0.0.0/0 → wsc2026-vpn-nat` | vpn-sn-a, vpn-sn-b |

**✅ 확인 (채점 12-1):**
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-vpn-vpc" \
  --query "Vpcs[*].{VpcId:VpcId,Name:Tags[?Key=='Name'].Value|[0],CidrBlock:CidrBlock}" --output table
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=wsc2026-vpn-vpc" --query "Vpcs[0].VpcId" --output text)" \
  --query "Subnets[*].{SubnetId:SubnetId,Name:Tags[?Key=='Name'].Value|[0],CidrBlock:CidrBlock,AZ:AvailabilityZone}" \
  --output table
```

## 4-2. 🖥️ EC2 `vpn-ec2`
먼저 **키 페어** 생성: `EC2 → 키 페어 → 키 페어 생성` → 이름 `vpn-ec2-key`, 유형 RSA, 형식 **.pem** → 다운로드(연결 테스트에 사용).

`EC2 → 인스턴스 시작`
| 항목 | 값 |
|------|-----|
| 이름 | `vpn-ec2` |
| AMI | **Amazon Linux 2023 (al2023)** |
| 인스턴스 유형 | **t3.micro** |
| 키 페어 | `vpn-ec2-key` |
| VPC | wsc2026-vpn-vpc |
| **서브넷** | **`wsc2026-vpn-sn-b`** (프라이빗) |
| 퍼블릭 IP 자동할당 | 비활성화 |
| 보안 그룹 | 신규 `vpn-ec2-sg` — 인바운드 **SSH 22** 및 **ICMP** 를 `10.0.0.0/16`, `172.16.0.0/22` 에서 허용 |

**✅ 확인 (채점 13-1):**
```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=vpn-ec2" \
  --query "Reservations[*].Instances[*].{InstanceId:InstanceId,Name:Tags[?Key=='Name'].Value|[0],Type:InstanceType,SubnetId:SubnetId,Status:State.Name}" \
  --output table
# → vpn-ec2 / running / t3.micro / (vpn-sn-b 서브넷)
```

## 4-3. 🔐 인증서 발급 + ACM 등록 (`cve.wsc`, `client.wsc`)

상호 인증(mutual TLS)이라 **서버 인증서**와 **클라이언트 인증서**가 필요합니다. CloudShell(싱가포르)에서 OpenVPN easy-rsa 로 발급합니다.

```bash
cd /tmp
git clone https://github.com/OpenVPN/easy-rsa.git
cd easy-rsa/easyrsa3
./easyrsa init-pki
./easyrsa --batch build-ca nopass                          # CA

# 서버 인증서 CN = cve.wsc
./easyrsa --batch --req-cn=cve.wsc gen-req cve.wsc nopass
./easyrsa --batch sign-req server cve.wsc

# 클라이언트 인증서 CN = client.wsc
./easyrsa --batch --req-cn=client.wsc gen-req client.wsc nopass
./easyrsa --batch sign-req client client.wsc

# ACM 업로드 (태그 Name 으로 cve.wsc / client.wsc 지정)
aws acm import-certificate --region ap-southeast-1 \
  --certificate      fileb://pki/issued/cve.wsc.crt \
  --private-key      fileb://pki/private/cve.wsc.key \
  --certificate-chain fileb://pki/ca.crt \
  --tags Key=Name,Value=cve.wsc

aws acm import-certificate --region ap-southeast-1 \
  --certificate      fileb://pki/issued/client.wsc.crt \
  --private-key      fileb://pki/private/client.wsc.key \
  --certificate-chain fileb://pki/ca.crt \
  --tags Key=Name,Value=client.wsc
```

**✅ 확인 (채점 14-1):**
```bash
aws acm list-certificates --region ap-southeast-1 \
  --query "CertificateSummaryList[?DomainName=='cve.wsc' || DomainName=='client.wsc'].{CertificateArn:CertificateArn,DomainName:DomainName}" \
  --output table
# → cve.wsc / client.wsc 두 개 표시
```

## 4-4. 🔗 Client VPN `wsc-vpn` + 연결 테스트

**콘솔 경로:** `VPC → Client VPN 엔드포인트 → 엔드포인트 생성`
| 항목 | 값 |
|------|-----|
| 이름 태그 | `wsc-vpn` |
| 클라이언트 IPv4 CIDR | `172.16.0.0/22` |
| 서버 인증서 ARN | `cve.wsc` |
| 인증 옵션 | **상호 인증(Mutual authentication)** |
| 클라이언트 인증서 ARN | `client.wsc` |
| 전송 프로토콜 | **UDP** |
| VPN 포트 | **1194** |
| **분할 터널** | **활성화** ← "엔드포인트 경로와 일치하는 트래픽만 VPN 통과" |
| IP 주소 유형 | IPv4 |
| VPC / 보안그룹 | wsc2026-vpn-vpc / UDP 1194 인바운드 허용 SG |

→ 생성 후 엔드포인트 선택:
1. **대상 네트워크 연결** 탭 → `대상 네트워크 연결` → 서브넷 **`wsc2026-vpn-sn-b`**
2. **인증 규칙** 탭 → `승인 규칙 추가` → 대상 CIDR `10.0.0.0/16`, **모든 사용자에게 액세스 허용**
3. 상태가 `Available` 될 때까지 대기(수 분)

**클라이언트 설정(.ovpn) 다운로드 & 접속:**
1. 엔드포인트 → **클라이언트 구성 다운로드** → `downloaded-client-config.ovpn`
2. 파일 하단에 클라이언트 인증서/키를 추가:
   ```
   <cert>
   (easy-rsa 의 pki/issued/client.wsc.crt 내용)
   </cert>
   <key>
   (easy-rsa 의 pki/private/client.wsc.key 내용)
   </key>
   ```
3. **AWS VPN Client** 또는 **OpenVPN Connect** 에 프로필로 불러와 **연결**.

**✅ 연결 테스트 (채점 14-2, powershell):**
```powershell
# VPN 연결 성공 후, vpn-ec2 의 프라이빗 IP 로 SSH
ssh -i "vpn-ec2-key.pem" ec2-user@<vpn-ec2 프라이빗 IP>
# → 접속 성공
```
> `<vpn-ec2 프라이빗 IP>` = 채점 13-1 출력 또는 EC2 콘솔의 프라이빗 IPv4. 키 파일은 4-2 에서 받은 `vpn-ec2-key.pem`.

---

## 🏁 마무리 · 자주 막히는 지점

| 증상 | 원인 / 해결 |
|------|-------------|
| API POST 는 되는데 GET 이 500 | Lambda 핸들러가 `handler.handler` 인지, `TABLE_NAME` 환경변수 확인 |
| 채점 2-2 정책 감점 | IAM 에 `dynamodb:PutItem`,`GetItem` **두 개만** — 관리형/와일드카드 금지 |
| db-client `read` = null | 먼저 `create` 실행. 그래도 실패면 Lambda VPC 서브넷·SG, Proxy `available` 확인 |
| db-client 타임아웃 | 계층(pymysql) 누락, 또는 SG 3306 인바운드(`10.0.0.0/16`) 누락 |
| transform 테스트 실패 | 버킷에 `test.json` 을 **먼저 업로드**했는지, S3 GetObject 권한 확인 |
| SFN 실행이 안 뜸 | S3 **EventBridge 알림 ON**, 규칙 대상=상태머신, 규칙 실행역할 StartExecution 확인 |
| VPN 연결 실패 | 대상 네트워크 연결(vpn-sn-b)·승인 규칙(10.0.0.0/16)·SG UDP1194, .ovpn 에 `<cert>/<key>` 추가했는지 |
| ssh 접속 안 됨 | EC2 SG 인바운드 SSH 22 를 `172.16.0.0/22`(VPN CIDR)에서 허용했는지 |

### 리전별 최종 점검
- [ ] **서울**: DynamoDB / Lambda / API GW(V1)
- [ ] **도쿄**: VPC / RDS(available) / Proxy(available) / db-client(read OK)
- [ ] **버지니아**: target-db / S3(EB ON) / transform / SFN / rule(ENABLED)
- [ ] **싱가포르**: VPC / vpn-ec2(running) / ACM 2종 / Client VPN(Available) / ssh 성공
- [ ] 진행 중인 **테스트 종료**, 불필요 리소스 정리(과제지 유의사항 9·11)

## 📌 참고
- **자동화(테라폼) 버전**: `../../01/2과제/` (module-1~4). 콘솔이 막히면 각 `main.tf` 의 값·구성을 대조하세요.
- Lambda 소스·정책 JSON 원본: 이 폴더 `files/module1~3/`.
- `<ACCOUNT_ID>`, `<vpn-ec2 프라이빗 IP>` 등 `<...>` 는 **모두 본인 값으로 치환** 후 실행.
