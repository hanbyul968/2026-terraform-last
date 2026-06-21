import json, os, boto3
from decimal import Decimal
from dotenv import load_dotenv

load_dotenv(dotenv_path="/opt/python/.env")

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.getenv("tableName"))


def _json_default(obj):
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError


def lambda_handler(event, context):
    if event["httpMethod"] == "GET":
        if event.get("queryStringParameters") is not None:
            if event["queryStringParameters"].get("admission_year") is not None and event["queryStringParameters"].get("student_name") is not None:
                if (isinstance(event["queryStringParameters"]["admission_year"], str) and len(str(event["queryStringParameters"]["admission_year"])) == 4) and isinstance(event["queryStringParameters"]["student_name"], str):
                    response = table.get_item(Key={"admission_year": int(event["queryStringParameters"]["admission_year"]), "student_name": event["queryStringParameters"]["student_name"]}).get("Item", None)
                    if response is not None:
                        return {
                            'statusCode': 200,
                            'body': json.dumps(response, default=_json_default, ensure_ascii=False)
                        }
                    else:
                        return {
                            'statusCode': 404,
                            'body': "찾을 수 없습니다."
                        }
                else:
                    return {
                        'statusCode': 400,
                        'body': "올바르게 입력해주세요."
                    }
            else:
                return {
                    'statusCode': 400,
                    'body': "필수 요청값을 입력해주세요."
                }
        else:
            return {
                'statusCode': 200,
                'body': json.dumps(table.scan().get("Items", []), default=_json_default, ensure_ascii=False)
            }
    elif event["httpMethod"] == "POST":
        if event["body"] is not None:
            body = json.loads(event["body"])
            if body.get("admission_year") is not None and body.get("student_name") is not None:
                if (isinstance(body["admission_year"], int) and len(str(body["admission_year"])) == 4) and isinstance(body["student_name"], str):
                    response = table.put_item(Item=body)["ResponseMetadata"]["HTTPStatusCode"]
                    if response == 200:
                        return {
                            'statusCode': response,
                            'body': json.dumps(body, default=_json_default, ensure_ascii=False)
                        }
                    else:
                        return {
                            'statusCode': response,
                            'body': "문제가 발생했습니다. 다시시도해주세요."
                        }
                else:
                    return {
                        'statusCode': 400,
                        'body': "올바르게 입력해주세요."
                    }
        return {
            'statusCode': 400,
            'body': "필수 요청값을 입력해주세요."
        }
    else:
        return {
            'statusCode': 405,
            'body': "잘못된 요청입니다."
        }
