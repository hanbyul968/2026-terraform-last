"""wsc2026-sensor-alert-consumer (MSK alert topic consumer).

배포파일 lambda.md 기준: Runtime python3.14 / Handler index.handler
  - 이상 데이터 수신 → SNS 알림 발송 + S3 /alert/{sensorId}/{date}/{timestamp}.json 저장
"""

import base64
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
S3_BUCKET = os.environ["S3_BUCKET"]

s3 = boto3.client("s3")
sns = boto3.client("sns")


def _records(event):
    for messages in event.get("records", {}).values():
        for message in messages:
            yield json.loads(base64.b64decode(message["value"]).decode("utf-8"))


def handler(event, context):
    records = list(_records(event))
    logger.info("Processing alert batch: %d messages", len(records))

    for record in records:
        sensor_id = record.get("sensorId", "unknown")
        timestamp = record.get("timestamp", "unknown")
        date = timestamp[:10] if len(timestamp) >= 10 else "unknown"
        key = f"alert/{sensor_id}/{date}/{timestamp}.json"
        body = json.dumps(record, ensure_ascii=False).encode("utf-8")

        s3.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=body,
            ContentType="application/json; charset=utf-8",
        )
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"Sensor alert: {sensor_id}",
            Message=json.dumps(
                {
                    "sensorId": sensor_id,
                    "timestamp": timestamp,
                    "temperature": record.get("temperature"),
                    "humidity": record.get("humidity"),
                    "alert_reason": record.get("alert_reason"),
                },
                ensure_ascii=False,
            ),
        )
        logger.info("%s: alert saved to s3://%s/%s", sensor_id, S3_BUCKET, key)

    return {"processed": len(records)}


# 이전 배포(handler=wsc2026.consumer_handler)와의 호환용 별칭
consumer_handler = handler
