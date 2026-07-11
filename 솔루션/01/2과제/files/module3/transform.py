import datetime
import boto3
import json

s3 = boto3.client('s3')


class ValidationError(Exception):
    pass


class TransformError(Exception):
    pass


def lambda_handler(event, context):
    try:
        # EventBridge/Step Functions 로부터 전달된 detail 에서 버킷/키를 읽는다
        bucket = event["detail"]["bucket"]["name"]
        key = event["detail"]["object"]["key"]

        response = s3.get_object(Bucket=bucket, Key=key)
        body = json.loads(response["Body"].read().decode("utf-8"))

        # 1) 필수 필드 검증 -> 없으면 ValidationError
        required_fields = ["id", "data"]
        for field in required_fields:
            if field not in body:
                raise ValidationError(f"Missing required field: '{field}'")

        # 2) 값이 null 이면 TransformError
        for field in required_fields:
            if body[field] is None:
                raise TransformError("Unexpected error during transform")

        # 3) 정상 -> status/processed_at 추가
        transformed = {
            "id": body["id"],
            "data": body["data"],
            "status": "processed",
            "processed_at": datetime.datetime.utcnow().isoformat() + "Z"
        }

        return {
            "statusCode": 200,
            "body": transformed
        }

    except ValidationError as e:
        # Custom Error 로 상위 워크플로우가 예외를 인지 (Catch: ValidationError)
        raise ValidationError(str(e))

    except Exception as e:
        raise TransformError(f"Unexpected error during transform: {str(e)}")
