import json
import os
from urllib.parse import unquote_plus

import boto3

stepfunctions = boto3.client("stepfunctions")
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    started = []
    for record in event.get("Records", []):
        key = unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("input/") or not key.endswith(".csv"):
            continue
        response = stepfunctions.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )
        started.append(response["executionArn"])

    return {"statusCode": 200, "started": started}
