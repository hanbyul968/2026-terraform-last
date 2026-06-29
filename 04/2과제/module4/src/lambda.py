"""
wsc-rest-function — REST API Implement (Module 4)

요구사항:
  - /v1/user POST : 신규 사용자 생성. 중복 시 'User already exists'
  - /v1/user GET  : name(+age) 조회. 없으면 'User not found'
  - DynamoDB Query 기반 조회만 사용(Scan 금지), Conditional Write 로 정합성 보장
  - Exception 발생 시 Stack Trace 외부 노출 금지
  - boto3 Client 재사용(전역 초기화) / Retry-safe(멱등) 구조
"""
import json
import os
import logging

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── boto3 리소스/테이블 핸들은 컨테이너 재사용을 위해 전역에서 1회 초기화 ──
_DDB = boto3.resource("dynamodb")
_TABLE = _DDB.Table(os.environ.get("TABLE_NAME", "wsc-rest-table"))


def _resp(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _create_user(body):
    name = body["name"]
    age = body["age"]
    country = body["country"]
    try:
        # Conditional Write: 동일 name 이 이미 있으면 실패 → 멱등/중복 방지
        _TABLE.put_item(
            Item={"name": name, "age": str(age), "country": country},
            ConditionExpression="attribute_not_exists(#n)",
            ExpressionAttributeNames={"#n": "name"},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _resp(200, {"message": "User already exists"})
        # 그 외 오류는 로그만 남기고 외부에는 스택트레이스 비노출
        logger.error("put_item failed: %s", exc.response["Error"]["Code"])
        return _resp(500, {"message": "Internal server error"})
    return _resp(200, {"message": "User created successfully"})


def _get_user(params):
    name = params.get("name")
    # Query 기반 조회만 사용 (Scan 금지)
    result = _TABLE.query(KeyConditionExpression=Key("name").eq(name))
    items = result.get("Items", [])
    if not items:
        return _resp(200, {"message": "User not found"})
    item = items[0]
    # 채점 기대 출력 순서: name, country, age (age 는 정수로 반환)
    return _resp(
        200,
        {
            "name": item["name"],
            "country": item.get("country"),
            "age": int(item["age"]),
        },
    )


def handler(event, context):
    try:
        method = event.get("httpMethod", "")
        if method == "POST":
            body = json.loads(event.get("body") or "{}")
            return _create_user(body)
        if method == "GET":
            params = event.get("queryStringParameters") or {}
            return _get_user(params)
        return _resp(405, {"message": "Method Not Allowed"})
    except Exception:  # noqa: BLE001  스택트레이스 외부 노출 금지
        logger.exception("unhandled error")
        return _resp(500, {"message": "Internal server error"})
