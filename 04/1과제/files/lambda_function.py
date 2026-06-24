import json
import os
import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ.get("TABLE_NAME", "wsc-table")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def _resp(status, body):
    # ALB(Lambda target) 응답 포맷
    return {
        "statusCode": status,
        "statusDescription": f"{status}",
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    # ALB 는 쿼리스트링을 queryStringParameters 로 전달
    qs = event.get("queryStringParameters") or {}
    client_id = qs.get("client_id")

    if not client_id:
        return _resp(400, {"msg": "client_id is required"})

    res = table.query(KeyConditionExpression=Key("client_id").eq(client_id))
    items = res.get("Items", [])

    if not items:
        return _resp(404, {"msg": "Item not found"})

    item = items[0]
    # 응답 스펙 (과제 15 API Spec)
    out = {
        "username": item.get("username"),
        "booking_id": item.get("booking_id"),
        "email": item.get("email"),
        "client_id": item.get("client_id"),
        "concert_name": item.get("concert_name"),
    }
    return _resp(200, out)
