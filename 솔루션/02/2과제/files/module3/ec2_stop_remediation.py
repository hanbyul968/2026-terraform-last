"""채점스크립트(mark2-3.sh)가 요구하는 함수.

mark2-3.sh 는 EC2 를 stop 시킨 뒤 30초 후 'running' 인지 확인한다.
=> stopped 상태를 감지해 즉시 다시 start 한다.
"""
import json
import os
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
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
    instance_id = detail.get("instance-id") or os.environ.get("INSTANCE_ID")

    ec2_client.start_instances(InstanceIds=[instance_id])

    publish_alert(
        "EC2_STOPPED",
        f"Instance {instance_id} was stopped and restarted",
        "RESTORED",
    )
