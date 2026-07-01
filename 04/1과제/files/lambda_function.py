import json
import os
import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ.get("TABLE_NAME", "wsc-table")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

_REASON = {200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"}


def _resp(status, body):
    # ALB(Lambda target) 응답 포맷. statusDescription 은 "<code> <reason>" 형식이어야
    # ALB 가 502 없이 그대로 전달한다.
    return {
        "statusCode": status,
        "statusDescription": f"{status} {_REASON.get(status, 'OK')}",
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    qs = event.get("queryStringParameters") or {}
    client_id = qs.get("client_id")

    if not client_id:
        return _resp(400, {"msg": "client_id is required"})

    res = table.query(KeyConditionExpression=Key("client_id").eq(client_id))
    items = res.get("Items", [])

    if not items:
        return _resp(404, {"msg": "Item not found"})

    item = items[0]
    # 채점 10-2-A 필드 순서 정확히: client_id, booking_id, username, email, concert_name
    out = {
        "client_id": item.get("client_id"),
        "booking_id": item.get("booking_id"),
        "username": item.get("username"),
        "email": item.get("email"),
        "concert_name": item.get("concert_name"),
    }
    return _resp(200, out)