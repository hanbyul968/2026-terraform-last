"""wsc2026-tag-alert
필수 태그 누락 등 Config 규칙 위반(NON_COMPLIANT) 감지 시 SNS 알림을 발행한다.
트리거: EventBridge (Config Rules Compliance Change - wsc2026-required-tags-rule)
"""
import json
import os

import boto3

sns = boto3.client("sns")
TOPIC = os.environ.get("SNS_TOPIC_ARN", "")


def handler(event, context):
    if TOPIC:
        sns.publish(
            TopicArn=TOPIC,
            Subject="Required Tag Violation",
            Message=json.dumps(event.get("detail", event), default=str),
        )
    return {"alerted": True}
