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
    instance_id = os.environ.get("INSTANCE_ID")
    original_type = os.environ.get("INSTANCE_TYPE", "t3.micro")

    current = ec2_client.describe_instances(InstanceIds=[instance_id])
    current_type = current["Reservations"][0]["Instances"][0]["InstanceType"]

    if current_type != original_type:
        ec2_client.stop_instances(InstanceIds=[instance_id])
        ec2_client.get_waiter("instance_stopped").wait(InstanceIds=[instance_id])

        ec2_client.modify_instance_attribute(
            InstanceId=instance_id,
            InstanceType={"Value": original_type},
        )

    ec2_client.start_instances(InstanceIds=[instance_id])

    publish_alert(
        "EC2_TYPE_CHANGED",
        f"Instance {instance_id} type was changed and restored to {original_type}",
        "RESTORED",
    )
