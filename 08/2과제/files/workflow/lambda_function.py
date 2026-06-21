import csv
import io
import os
from decimal import Decimal

import boto3

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def lambda_handler(event, context):
    table_name = os.environ["TABLE_NAME"]
    table = dynamodb.Table(table_name)

    bucket = event.get("bucket") or event.get("Bucket")
    key = event.get("key") or event.get("Key") or "data.csv"

    if not bucket:
        raise ValueError("Input must include bucket")

    obj = s3.get_object(Bucket=bucket, Key=key)
    body = obj["Body"].read().decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(body))

    count = 0
    with table.batch_writer(overwrite_by_pkeys=["id"]) as batch:
        for row in reader:
            item = {
                "id": row["id"],
                "product_id": row["product_id"],
                "category": row["category"],
                "price": Decimal(row["price"]),
            }
            batch.put_item(Item=item)
            count += 1

    return {
        "statusCode": 200,
        "table": table_name,
        "bucket": bucket,
        "key": key,
        "saved": count,
    }
