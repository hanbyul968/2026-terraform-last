import json
import os
import decimal
import boto3
from boto3.dynamodb.conditions import Key

import json
import os
import decimal
import boto3
from boto3.dynamodb.conditions import Key

# 환경 변수에서 DynamoDB 테이블 이름 가져오기
TABLE_NAME = os.environ["TABLE_NAME"]

# 환경 변수에서 GSI 이름 가져오기
GSI_NAME = os.environ["GSI_NAME"]

# DynamoDB 연결
dynamodb = boto3.resource("dynamodb")

# 사용할 테이블 선택
table = dynamodb.Table(TABLE_NAME)

# HTTP 상태 코드와 메시지
_REASON = {
    200: "OK",
    400: "Bad Request",
    404: "Not Found",
    500: "Internal Server Error",
}


# Decimal 타입을 JSON으로 변환
def _json_default(o):
    if isinstance(o, decimal.Decimal):
        # 소수점이 없으면 int
        if o % 1 == 0:
            return int(o)

        # 소수점이 있으면 float
        return float(o)

    raise TypeError(f"not serializable: {type(o)}")


# API Gateway가 요구하는 응답 형식 생성
def _resp(status, body):
    return {
        # HTTP 상태 코드
        "statusCode": status,

        # 상태 설명
        "statusDescription": (
            f"{status} {_REASON.get(status, 'OK')}"
        ),

        # Base64 사용 안 함
        "isBase64Encoded": False,

        # 응답 형식(JSON)
        "headers": {
            "Content-Type": "application/json"
        },

        # 응답 데이터(JSON 문자열)
        "body": json.dumps(
            body,
            ensure_ascii=False,
            default=_json_default,
        ),
    }


# Lambda 시작 함수
def handler(event, context):

    # URL Query String 가져오기
    # 예) ?concert_name=IU
    qs = event.get("queryStringParameters") or {}

    # concert_name 값 가져오기
    concert_name = qs.get("concert_name")

    # concert_name이 없으면 오류 반환
    if not concert_name:
        return _resp(
            400,
            {"message": "concert_name is required"}
        )

    # GSI를 이용해 concert_name으로 조회
    res = table.query(
        IndexName=GSI_NAME,

        # concert_name이 같은 데이터 검색
        KeyConditionExpression=Key(
            "concert_name"
        ).eq(concert_name),

        # 최신(created_at 큰 값)부터 정렬
        ScanIndexForward=False,
    )

    # 조회 결과 가져오기
    items = res.get("Items", [])

    # 출력 필드 순서 지정
    items = [
        {
            "username": item.get("username"),
            "created_at": item.get("created_at"),
            "email": item.get("email"),
            "booking_id": item.get("booking_id"),
            "client_id": item.get("client_id"),
            "concert_name": item.get("concert_name"),
        }
        for item in items
    ]

    # 조회 결과 반환
    return _resp(200, items)