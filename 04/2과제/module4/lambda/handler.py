import json
import os
import boto3
from botocore.exceptions import ClientError

# boto3 client/resource 는 컨테이너 재사용을 위해 전역에서 1회 초기화
_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["TABLE_NAME"])


def _resp(code, body):
    return {"statusCode": code, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body)}


def handler(event, context):
    try:
        method = event.get("httpMethod")

        if method == "POST":
            # API GW 에서 body(name/age/country) validation 완료 → 여기 도달 시 정상 스키마
            body = json.loads(event.get("body") or "{}")
            name = str(body["name"])
            age = int(body["age"])
            country = str(body["country"])
            try:
                # Conditional Write: 동일 (name, age) 항목이 있으면 실패 → 멱등/중복 방지
                _table.put_item(
                    Item={"name": name, "age": age, "country": country},
                    ConditionExpression="attribute_not_exists(#n)",
                    ExpressionAttributeNames={"#n": "name"},
                )
            except ClientError as e:
                if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    return _resp(200, {"message": "User already exists"})
                raise
            return _resp(201, {"message": "User created successfully"})

        if method == "GET":
            # API GW request validation 이 name/age 필수 파라미터를 강제 (미충족 시 여기 도달 안 함)
            params = event.get("queryStringParameters") or {}
            name = params.get("name")
            age = params.get("age")
            if not name or not age:
                return _resp(400, {"message": "Missing required request parameters: [age]"})
            res = _table.get_item(Key={"name": str(name), "age": int(age)})
            item = res.get("Item")
            if not item:
                return _resp(404, {"message": "User not found"})
            return _resp(200, {
                "name": item["name"],
                "age": int(item["age"]),
                "country": item.get("country"),
            })

        return _resp(405, {"message": "Method Not Allowed"})
    except Exception:
        # Stack trace 외부 비노출
        return _resp(500, {"message": "Internal Server Error"})
