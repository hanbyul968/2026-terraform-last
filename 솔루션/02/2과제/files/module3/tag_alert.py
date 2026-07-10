"""채점스크립트(mark2-3.sh)가 요구하는 함수.

AWS Config 규칙 wsc2026-required-tags-rule 의 NON_COMPLIANT 평가를 수신해
SNS 로 알림만 발송한다. (remediation 없음)
"""
import json
import os
from datetime import datetime, timezone

import boto3

sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def handler(event, context):
    detail = event.get("detail", {})
    resource_id = detail.get("resourceId", "unknown")

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({
            "event": "TAG_NON_COMPLIANT",
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "detail": f"Resource {resource_id} is missing required tags",
            "action": "ALERT_ONLY",
        }),
    )
