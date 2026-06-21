import base64
import json
import os

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "order-records")
AWS_REGION_NAME = os.environ.get("AWS_REGION_NAME", "ap-northeast-3")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION_NAME)
table = dynamodb.Table(DYNAMODB_TABLE_NAME)


def parse_msk_record(record: dict) -> dict:
    raw_value = record.get("value", "")
    decoded_bytes = base64.b64decode(raw_value)
    return json.loads(decoded_bytes.decode("utf-8"))


def save_to_dynamodb(order: dict) -> bool:
    order_id = order.get("orderId")
    timestamp = order.get("timestamp")

    if not order_id or not timestamp:
        return False

    item = {
        "orderId": order_id,
        "timestamp": timestamp,
        "region": order.get("region", "unknown"),
        "product": order.get("product", {}),
        "quantity": order.get("quantity", 0),
        "totalPrice": order.get("totalPrice", 0),
        "status": order.get("status", "UNKNOWN"),
    }

    try:
        table.put_item(
            Item=item,
            ConditionExpression=Attr("orderId").not_exists(),
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return True
        return False


def handler(event, context):
    records_by_partition = event.get("records", {})
    batch_item_failures = []
    total = 0
    success = 0

    for partition_key, records in records_by_partition.items():
        for record in records:
            total += 1
            sequence_number = record.get("offset", "unknown")
            try:
                order = parse_msk_record(record)
                if save_to_dynamodb(order):
                    success += 1
                else:
                    batch_item_failures.append({"itemIdentifier": str(sequence_number)})
            except Exception:
                batch_item_failures.append({"itemIdentifier": str(sequence_number)})

    return {"batchItemFailures": batch_item_failures}
