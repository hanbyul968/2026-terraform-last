import json
import os
import boto3
from boto3.dynamodb.conditions import Key

# 연결에 필요한 값은 환경변수로 주입 (하드코딩 금지, Reference03)
TABLE_NAME = os.environ["TABLE_NAME"]
GSI_NAME = os.environ.get("GSI_NAME", "concert_name-created_at-index")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def _resp(status, body):
    # ALB(Lambda target) 응답 포맷
    return {
        "statusCode": status,
        "statusDescription": str(status),
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def handler(event, context):
    qs = event.get("queryStringParameters") or {}
    concert_name = qs.get("concert_name")

    # concert_name 파라미터가 없으면 400
    if not concert_name:
        return _resp(400, {"message": "concert_name is required"})

    # GSI 로 concert_name 조회 + created_at 최신순(ScanIndexForward=False)
    res = table.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("concert_name").eq(concert_name),
        ScanIndexForward=False,
    )
    items = res.get("Items", [])

    # 결과 없으면 빈 배열 + 200
    return _resp(200, items)
