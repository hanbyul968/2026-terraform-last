"""wsc2026-ec2-terminate-alert
EC2 인스턴스 종료(terminated) 감지 시 SNS 알림을 발행한다.
트리거: EventBridge wsc2026-ec2-terminate-rule
"""
import os

import boto3

sns = boto3.client("sns")
TOPIC = os.environ.get("SNS_TOPIC_ARN", "")


def handler(event, context):
    detail = event.get("detail", {}) or {}
    iid = detail.get("instance-id") or detail.get("instanceId") or "unknown"
    if TOPIC:
        sns.publish(
            TopicArn=TOPIC,
            Subject="EC2 Terminate Alert",
            Message=f"Instance {iid} was terminated.",
        )
    return {"alerted": iid}
