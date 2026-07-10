# 모듈 1 — NoSQL (콘솔 솔루션)

**리전: `ap-southeast-1` (싱가포르)** — 우측 상단에서 리전을 먼저 바꾸세요.

좌석 예약 시스템: DynamoDB(예약/감사) + Streams → Lambda 후처리 + EC2(Flask) API.

## 만들 리소스 요약
| 리소스 | 이름 | 핵심 설정 |
|--------|------|-----------|
| DynamoDB | `bigbae-nosql-reservation-table` | PK train_id / SK seat_id, Stream NEW_AND_OLD_IMAGES, PITR, GSI |
| DynamoDB | `bigbae-nosql-audit-table` | PK event_id |
| Lambda | `bigbae-nosql-reservation-audit` | python3.13, Timeout 30, Streams 트리거 |
| EC2 | `bigbae-nosql-app-ec2` | t3.small, AL2023, 8080, Public IP |

---

## 1. DynamoDB — Reservation Table

콘솔 → **DynamoDB** → **테이블 생성**

1. **테이블 이름**: `bigbae-nosql-reservation-table`
2. **파티션 키**: `train_id` — 타입 **문자열(String)**
3. **정렬 키**: `seat_id` — 타입 **문자열(String)**
4. **테이블 설정**: **설정 사용자 지정** 선택
5. **읽기/쓰기 용량**: **온디맨드(On-demand)** ← PAY_PER_REQUEST
6. **테이블 생성** 클릭.

### 1-1. 스트림 활성화
1. 생성된 테이블 클릭 → **내보내기 및 스트림(Exports and streams)** 탭
2. **DynamoDB 스트림** → **켜기(Turn on)**
3. **보기 유형**: **새 이미지와 이전 이미지(New and old images)** 선택 → **스트림 켜기**

### 1-2. PITR(Point-in-time recovery) 활성화
1. **백업(Backups)** 탭 → **Point-in-time recovery** → **편집/켜기**
2. **PITR 켜기** 확인.

### 1-3. GSI 생성
1. **인덱스(Indexes)** 탭 → **인덱스 생성**
2. **파티션 키**: `user_id` (문자열)
3. **정렬 키**: `reserved_at` (문자열)
4. **인덱스 이름**: `gsi-user-reservations`
5. **속성 프로젝션(Attribute projections)**: **모두(All)**
6. **인덱스 생성**.

> ✅ 채점 1-1/1-2 기대값: HASH train_id / RANGE seat_id, Stream NEW_AND_OLD_IMAGES,
> Billing PAY_PER_REQUEST, PITR ENABLED, GSI(user_id/reserved_at, ALL)

---

## 2. DynamoDB — Audit Table

콘솔 → **DynamoDB** → **테이블 생성**
1. **테이블 이름**: `bigbae-nosql-audit-table`
2. **파티션 키**: `event_id` — **문자열**
3. **정렬 키**: 없음
4. **설정 사용자 지정** → **온디맨드**
5. **테이블 생성**.

---

## 3. Lambda — Streams 후처리

### 3-1. Lambda 함수 생성
콘솔 → **Lambda** → **함수 생성**
1. **새로 작성** 선택
2. **함수 이름**: `bigbae-nosql-reservation-audit`
3. **런타임**: **Python 3.13**
4. **아키텍처**: x86_64
5. **함수 생성**.

### 3-2. 코드 붙여넣기
**코드(Code)** 탭 → `lambda_function.py` 내용을 지우고 아래 코드 붙여넣기 →
**Deploy**.

> ⚠️ 파일명이 `lambda_function.py` 로 되어 있으면, 아래 3-4의 **핸들러**를
> `lambda_function.handler` 로 맞추거나, 파일명을 `lambda.py` 로 바꾸고 핸들러를
> `lambda.handler` 로 설정하세요. (아래 예시는 파일명 `lambda_function.py` 기준)

```python
import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer

AUDIT_TABLE_NAME = os.environ.get("AUDIT_TABLE_NAME", "bigbae-nosql-audit-table")

dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(AUDIT_TABLE_NAME)
_deserializer = TypeDeserializer()


def _deserialize_image(image: dict | None) -> dict:
    if not image:
        return {}
    return {key: _deserializer.deserialize(value) for key, value in image.items()}


def handler(event, context):
    for record in event.get("Records", []):
        new_image = _deserialize_image(record["dynamodb"].get("NewImage"))
        old_image = _deserialize_image(record["dynamodb"].get("OldImage"))
        image = new_image or old_image

        audit_table.put_item(
            Item={
                "event_id": str(uuid.uuid4()),
                "train_id": image.get("train_id"),
                "seat_id": image.get("seat_id"),
                "user_id": image.get("user_id"),
                "occurred_at": datetime.now(timezone.utc).isoformat(),
                "stream_event": record.get("eventName"),
                "old_status": old_image.get("status"),
                "new_status": new_image.get("status"),
            }
        )

    return {"statusCode": 200}
```

### 3-3. 환경 변수 & 타임아웃
1. **구성(Configuration)** → **환경 변수** → **편집** →
   - 키 `AUDIT_TABLE_NAME` / 값 `bigbae-nosql-audit-table` → 저장
2. **구성** → **일반 구성** → **편집** → **제한 시간(Timeout)** `0분 30초` → 저장

### 3-4. 핸들러 확인
- **구성** → **런타임 설정** → **편집** → **핸들러**를 `lambda_function.handler`
  (파일명이 `lambda.py`면 `lambda.handler`) 로 설정.

### 3-5. 실행 역할 권한 추가
1. **구성** → **권한** → 실행 역할 링크 클릭 → IAM 역할 페이지 이동
2. **권한 추가** → **인라인 정책 생성** → JSON 탭에 아래 붙여넣기
   (`<AUDIT_ARN>` / `<RES_STREAM_ARN>` 은 각 테이블 콘솔의 ARN 으로 교체)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/bigbae-nosql-audit-table"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetRecords",
        "dynamodb:GetShardIterator",
        "dynamodb:DescribeStream",
        "dynamodb:ListStreams"
      ],
      "Resource": "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/bigbae-nosql-reservation-table/stream/*"
    }
  ]
}
```
3. 정책 이름 `bigbae-nosql-lambda-policy` → 생성.
   (기본 `AWSLambdaBasicExecutionRole` 로 CloudWatch Logs 권한은 이미 있음)

### 3-6. Streams 트리거 연결
1. Lambda 함수 → **함수 개요** → **트리거 추가**
2. **소스**: **DynamoDB**
3. **DynamoDB 테이블**: `bigbae-nosql-reservation-table`
4. **시작 위치**: Latest, **배치 크기**: 10 (기본)
5. **활성화** 체크 → **추가**.

> ✅ 채점 1-3 기대값: Runtime python3.13, Timeout 30,
> Event Source Mapping Source=bigbae-nosql-reservation-table, State **Enabled**

---

## 4. 네트워크 (VPC)

콘솔 → **VPC** → **VPC 생성** → **VPC 등 여러 리소스(VPC and more)** 선택하면 서브넷/IGW/라우팅을 한 번에 만들 수 있습니다. 수동이라면:

1. **VPC 생성**: 이름 `bigbae-nosql-vpc`, CIDR `10.0.0.0/16` → DNS 호스트names 활성화
2. **인터넷 게이트웨이**: `bigbae-nosql-igw` 생성 → VPC에 연결
3. **서브넷**: `bigbae-nosql-pub-subnet`, VPC 선택, AZ `ap-southeast-1a`, CIDR `10.0.1.0/24`
   - 서브넷 → 작업 → **자동 할당 IP 설정 편집** → 퍼블릭 IPv4 자동 할당 **켜기**
4. **라우팅 테이블**: `bigbae-nosql-pub-rt` 생성 → 서브넷 연결 → 경로 추가 `0.0.0.0/0` → IGW

---

## 5. EC2 — Flask 앱

### 5-1. EC2 IAM 역할
콘솔 → **IAM** → **역할** → **역할 생성**
1. **신뢰 엔터티**: AWS 서비스 → **EC2**
2. 권한 없이 다음 단계 → 이름 `bigbae-nosql-ec2-role` → 생성
3. 생성된 역할 → **인라인 정책 생성** → JSON:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem",
      "dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan"
    ],
    "Resource": [
      "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/bigbae-nosql-reservation-table",
      "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/bigbae-nosql-reservation-table/index/*"
    ]
  }]
}
```
   이름 `bigbae-nosql-ec2-policy` → 생성.

### 5-2. 보안 그룹
콘솔 → **EC2** → **보안 그룹** → **생성**
1. 이름 `bigbae-nosql-app-sg`, VPC `bigbae-nosql-vpc`
2. **인바운드 규칙**: 사용자 지정 TCP, 포트 `8080`, 소스 `0.0.0.0/0`
3. **아웃바운드 규칙**: TCP 80 `0.0.0.0/0`, TCP 443 `0.0.0.0/0` (Anyopen)
4. 생성.

### 5-3. 인스턴스 시작
콘솔 → **EC2** → **인스턴스 시작**
1. **이름**: `bigbae-nosql-app-ec2`
2. **AMI**: **Amazon Linux 2023**
3. **인스턴스 유형**: **t3.small**
4. **키 페어**: 없음(SSM 사용 안 하면 없어도 됨)
5. **네트워크 설정** → 편집:
   - VPC `bigbae-nosql-vpc`, 서브넷 `bigbae-nosql-pub-subnet`
   - 퍼블릭 IP 자동 할당 **활성화**
   - 기존 보안 그룹 `bigbae-nosql-app-sg` 선택
6. **고급 세부 정보** → **IAM 인스턴스 프로파일**: `bigbae-nosql-ec2-role`
7. **고급 세부 정보** → **사용자 데이터**에 아래 붙여넣기:

```bash
#!/bin/bash
dnf install -y python3.11 python3.11-pip
pip3.11 install flask boto3
mkdir -p /opt/app
cat > /opt/app/app.py << 'APPEOF'
```
👉 **여기(APPEOF 다음 줄)에 아래 `app.py` 전체를 붙여넣고**, 이어서 `APPEOF` 와 나머지 스크립트를 붙입니다:

```bash
APPEOF
cd /opt/app
export AWS_REGION=ap-southeast-1
export TABLE_NAME=bigbae-nosql-reservation-table
export GSI_NAME=gsi-user-reservations
nohup python3.11 app.py &
```

**app.py 전체 (위 APPEOF 사이에 넣을 내용):**
```python
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "ap-southeast-1")
TABLE_NAME = os.environ.get("TABLE_NAME", "bigbae-nosql-reservation-table")
GSI_NAME = os.environ.get("GSI_NAME", "gsi-user-reservations")

table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(TABLE_NAME)


@app.route("/healthcheck", methods=["GET"])
def healthcheck():
    return "", 200


@app.route("/reserve", methods=["POST"])
def reserve():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")
    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400
    reserved_at = datetime.now(timezone.utc).isoformat()
    try:
        response = table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :reserved, #version = if_not_exists(#version, :zero) + :one, "
                "user_id = :user_id, reserved_at = :reserved_at"
            ),
            ConditionExpression="attribute_not_exists(#status) OR #status = :available",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":reserved": "reserved", ":available": "available",
                ":zero": 0, ":one": 1,
                ":user_id": user_id, ":reserved_at": reserved_at,
            },
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "already reserved"}), 409
        raise
    item = response["Attributes"]
    return jsonify({"status": "reserved", "seat_id": seat_id, "version": int(item["version"])}), 200


@app.route("/cancel", methods=["POST"])
def cancel():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")
    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400
    try:
        table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :available, #version = if_not_exists(#version, :zero) + :one "
                "REMOVE user_id, reserved_at"
            ),
            ConditionExpression="#status = :reserved AND user_id = :user_id",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":available": "available", ":reserved": "reserved",
                ":zero": 0, ":one": 1, ":user_id": user_id,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "not owner"}), 409
        raise
    return jsonify({"status": "cancelled", "seat_id": seat_id}), 200


@app.route("/seats/<train_id>", methods=["GET"])
def seats(train_id):
    response = table.query(KeyConditionExpression=Key("train_id").eq(train_id))
    items = [{"seat_id": i["seat_id"], "status": i.get("status", "available"),
              "user_id": i.get("user_id")} for i in response.get("Items", [])]
    return jsonify(items), 200


@app.route("/my-bookings/<user_id>", methods=["GET"])
def my_bookings(user_id):
    response = table.query(IndexName=GSI_NAME,
                           KeyConditionExpression=Key("user_id").eq(user_id))
    items = [{"train_id": i["train_id"], "seat_id": i["seat_id"],
              "reserved_at": i["reserved_at"]} for i in response.get("Items", [])]
    return jsonify(items), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

8. **인스턴스 시작**. 부팅 후 1~2분이면 앱 기동.

---

## 6. 검증 (채점 기준)

CloudShell(ap-southeast-1) 또는 로컬에서:

```bash
EC2_IP=$(aws ec2 describe-instances --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=bigbae-nosql-app-ec2" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].PublicIpAddress" --output text)

# 1-4 healthcheck 200
curl -s -o /dev/null -w "healthcheck %{http_code}\n" "http://${EC2_IP}:8080/healthcheck"

# 1-5 Conditional Write (reserve→200, 중복→409, 남의 취소→409, 본인 취소→200)
T=train-$(date +%s); S=A1
R(){ curl -s -w" %{http_code}" -X POST http://$EC2_IP:8080/$1 -H Content-Type:application/json \
   -d "{\"train_id\":\"$T\",\"seat_id\":\"$S\",\"user_id\":\"$2\"}"; echo; }
R reserve user1; R reserve user2; R cancel user2; R cancel user1
```
기대:
```
healthcheck 200
{"seat_id":"A1","status":"reserved","version":1} 200
{"error":"already reserved"} 409
{"error":"not owner"} 409
{"seat_id":"A1","status":"cancelled"} 200
```

> Flask 가 JSON 키를 알파벳순으로 정렬해 출력하므로 `seat_id`→`status`→`version` 순서로 나옵니다(정답과 일치).

1-6 (Streams 후처리): reserve 후 30초 뒤 audit 1건, cancel 후 audit 2건이면 정상.
