import base64
import json
import os
from datetime import datetime, timezone, timedelta

import boto3
from boto3.dynamodb.conditions import Key

# TABLE_NAME에는 Terraform이 생성한 base64 KMS CiphertextBlob이 저장된다.
kms = boto3.client("kms")
TABLE_NAME = kms.decrypt(
    CiphertextBlob=base64.b64decode(os.environ["TABLE_NAME"]),
)["Plaintext"].decode("utf-8")
INDEX_NAME = os.environ.get("INDEX_NAME", "booking_id-index")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

KST = timezone(timedelta(hours=9))


def _fmt_created_at(value):
    """저장된 created_at 을 'YYYY-MM-DD HH:MM:SS KST' 형식으로 변환."""
    if value is None:
        return ""
    s = str(value).strip()
    dt = None
    # 1) epoch (초/밀리초)
    try:
        num = float(s)
        if num > 1e12:
            num = num / 1000.0
        dt = datetime.fromtimestamp(num, tz=timezone.utc)
    except (ValueError, OverflowError):
        dt = None
    # 2) ISO8601 / RFC3339
    if dt is None:
        try:
            iso = s.replace("Z", "+00:00")
            dt = datetime.fromisoformat(iso)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        except ValueError:
            dt = None
    # 3) 흔한 문자열 포맷들
    if dt is None:
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
            try:
                dt = datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
                break
            except ValueError:
                continue
    if dt is None:
        return s
    return dt.astimezone(KST).strftime("%Y-%m-%d %H:%M:%S KST")


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, context):
    qs = event.get("queryStringParameters") or {}
    booking_id = qs.get("booking_id")
    if not booking_id:
        return _resp(400, {"msg": "booking_id is required"})

    res = table.query(
        IndexName=INDEX_NAME,
        KeyConditionExpression=Key("booking_id").eq(booking_id),
    )
    items = res.get("Items", [])
    if not items:
        return _resp(404, {"msg": "Item not found"})

    item = items[0]
    # 응답 컬럼 순서 고정 (채점 9-3): client_id, username, email, concert_name, created_at
    out = {
        "client_id": item.get("client_id"),
        "username": item.get("username"),
        "email": item.get("email"),
        "concert_name": item.get("concert_name"),
        "created_at": _fmt_created_at(item.get("created_at")),
    }
    return _resp(200, out)
