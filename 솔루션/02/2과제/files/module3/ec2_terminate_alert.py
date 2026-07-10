import json
import os
from datetime import datetime, timezone

import boto3

sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def publish_alert(event_type, detail, action):
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({
            "event": event_type,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "detail": detail,
            "action": action,
        }),
    )


def handler(event, context):
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "unknown")

    publish_alert(
        "EC2_TERMINATED",
        f"Instance {instance_id} was terminated",
        "ALERT_ONLY",
    )
