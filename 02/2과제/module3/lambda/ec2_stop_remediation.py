"""wsc2026-ec2-stop-remediation
EC2 가 중지(stopped)되면 다시 시작하여 running 상태로 복구하고 SNS 로 알린다.
트리거: EventBridge wsc2026-ec2-stop-rule (EC2 Instance State-change -> stopped)
"""
import os

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")
TOPIC = os.environ.get("SNS_TOPIC_ARN", "")


def handler(event, context):
    detail = event.get("detail", {}) or {}
    iid = detail.get("instance-id") or detail.get("instanceId")
    if not iid:
        return {"skipped": True}
    ec2.start_instances(InstanceIds=[iid])
    if TOPIC:
        sns.publish(
            TopicArn=TOPIC,
            Subject="EC2 Stop Remediation",
            Message=f"Instance {iid} was stopped; restart initiated.",
        )
    return {"remediated": iid}
