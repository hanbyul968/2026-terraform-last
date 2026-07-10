"""wsc2026-sensor-alert-consumer

MSK 토픽 wsc2026-sensor-alert 를 소비해
 - SNS 알림 발송
 - S3 에 /alert/{sensorId}/{date}/{timestamp}.json 저장
"""
import base64
import json
import os

import boto3

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
S3_BUCKET = os.environ["S3_BUCKET"]

sns = boto3.client("sns")
s3 = boto3.client("s3")


def handler(event, context):
    records = [r for batch in event.get("records", {}).values() for r in batch]
    print(f"Processing batch: {len(records)} alert messages")

    for record in records:
        data = json.loads(base64.b64decode(record["value"]).decode("utf-8"))

        sensor_id = data["sensorId"]
        timestamp = data["timestamp"]
        date = timestamp.split("T")[0]

        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[ALERT] {sensor_id}",
            Message=json.dumps({
                "sensorId": sensor_id,
                "timestamp": timestamp,
                "temperature": data.get("temperature"),
                "humidity": data.get("humidity"),
                "alert_reason": data.get("alert_reason"),
            }, ensure_ascii=False),
        )

        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"alert/{sensor_id}/{date}/{timestamp}.json",
            Body=json.dumps(data, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json; charset=utf-8",
        )

    return {"statusCode": 200}
