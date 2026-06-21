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
        bucket = event["detail"]["bucket"]["name"]
        key = event["detail"]["object"]["key"]

        response = s3.get_object(Bucket=bucket, Key=key)
        body = json.loads(response["Body"].read().decode("utf-8"))

        required_fields = ["id", "data"]
        for field in required_fields:
            if field not in body:
                raise ValidationError(f"Missing required field: '{field}'")

        for field in required_fields:
            if body[field] is None:
                raise TransformError("Unexpected error during transform")

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
        raise ValidationError(str(e))

    except Exception as e:
        raise TransformError(f"Unexpected error during transform: {str(e)}")
