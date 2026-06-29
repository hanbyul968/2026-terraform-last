import os
import json
import base64
import boto3

ddb = boto3.resource("dynamodb")
s3 = boto3.client("s3")
sns = boto3.client("sns")

TABLE = os.environ.get("TABLE_NAME")
ALERT_BUCKET = os.environ.get("ALERT_BUCKET")
ALERT_TOPIC = os.environ.get("ALERT_TOPIC")


def _records(event):
    out = []
    for _tp, msgs in event.get("records", {}).items():
        for m in msgs:
            raw = base64.b64decode(m["value"]).decode("utf-8")
            try:
                out.append(json.loads(raw))
            except Exception:
                out.append({"raw": raw})
    return out


def raw_handler(event, context):
    # wsc2026-sensor-raw -> DynamoDB(wsc2026-sensor-data)
    table = ddb.Table(TABLE)
    for r in _records(event):
        if "sensorId" in r and "timestamp" in r:
            table.put_item(Item={k: str(v) for k, v in r.items()})
    return {"ok": True}


def alert_handler(event, context):
    # wsc2026-sensor-alert -> S3 + SNS
    for r in _records(event):
        key = f"alerts/{r.get('sensorId','unknown')}-{r.get('timestamp','0')}.json"
        s3.put_object(Bucket=ALERT_BUCKET, Key=key, Body=json.dumps(r).encode())
        sns.publish(TopicArn=ALERT_TOPIC, Subject="Sensor anomaly", Message=json.dumps(r))
    return {"ok": True}
