"""wsc2026-sensor-alert-consumer
MSK 토픽 wsc2026-sensor-alert 의 이상치 메시지를 소비하여 SNS 알림 발행 +
S3(wsc2026-sensor-alert-bucket-<비번호>)에 오류 데이터 저장.
"""
import base64
import os
import time

import boto3

sns = boto3.client("sns")
s3 = boto3.client("s3")
TOPIC = os.environ["SNS_TOPIC_ARN"]
BUCKET = os.environ["ALERT_BUCKET"]


def handler(event, context):
    count = 0
    for _tp, recs in (event.get("records") or {}).items():
        for r in recs:
            raw = base64.b64decode(r["value"]).decode("utf-8")
            sns.publish(TopicArn=TOPIC, Subject="Sensor Anomaly Alert", Message=raw)
            s3.put_object(
                Bucket=BUCKET,
                Key=f"alert/{int(time.time() * 1000)}.json",
                Body=raw.encode("utf-8"),
                ContentType="application/json",
            )
            count += 1
    return {"alerted": count}
