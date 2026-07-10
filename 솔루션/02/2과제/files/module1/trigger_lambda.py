import json
import os
import urllib.parse

import boto3

sfn = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        if not key.startswith("input/") or not key.endswith(".csv"):
            continue

        sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"key": key}),
        )

    return {"statusCode": 200}
