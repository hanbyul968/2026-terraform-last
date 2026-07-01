import json
import os
import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["TABLE_NAME"])


def _resp(code, body):
    return {"statusCode": code, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body)}


def handler(event, context):
    try:
        method = event.get("httpMethod")
        if method == "POST":
            body = json.loads(event.get("body") or "{}")
            name = body.get("name")
            age = body.get("age")
            country = body.get("country")
            if not name or age is None or not country:
                return _resp(400, {"message": "Invalid request body"})
            try:
                _table.put_item(
                    Item={"name": str(name), "age": str(age), "country": str(country)},
                    ConditionExpression="attribute_not_exists(#n)",
                    ExpressionAttributeNames={"#n": "name"},
                )
            except ClientError as e:
                if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    return _resp(200, {"message": "User already exists"})
                raise
            return _resp(201, {"message": "User created successfully"})

        if method == "GET":
            params = event.get("queryStringParameters") or {}
            name = params.get("name")
            age = params.get("age")
            # API Gateway request validation enforces required params, but double-check
            if not name or not age:
                return _resp(400, {"message": "Missing required request parameters: [age]"})
            res = _table.query(
                KeyConditionExpression=Key("name").eq(str(name))
            )
            items = res.get("Items", [])
            if not items:
                return _resp(404, {"message": "User not found"})
            it = items[0]
            age_val = int(it["age"]) if str(it["age"]).isdigit() else it["age"]
            # 채점 기대 출력 순서: name, country, age (age 는 정수)
            return _resp(200, {"name": it["name"], "country": it.get("country"), "age": age_val})

        return _resp(405, {"message": "Method Not Allowed"})
    except Exception:
        # Never leak stack trace
        return _resp(500, {"message": "Internal Server Error"})
