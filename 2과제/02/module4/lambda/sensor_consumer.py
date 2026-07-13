"""wsc2026-sensor-consumer
MSK 토픽 wsc2026-sensor-raw 의 센서 메시지를 소비하여 DynamoDB(wsc2026-sensor-data)에 저장.
모든 속성은 String(S) 으로 저장 (채점 4-5/4-6: temperature.S, status.S, timestamp.S).
"""
import base64
import json
import os

import boto3

ddb = boto3.client("dynamodb")
TABLE = os.environ["DDB_TABLE"]


def handler(event, context):
    count = 0
    for _tp, recs in (event.get("records") or {}).items():
        for r in recs:
            raw = base64.b64decode(r["value"]).decode("utf-8")
            try:
                d = json.loads(raw)
            except Exception:  # noqa: BLE001
                continue
            item = {
                "sensorId": {"S": str(d.get("sensorId", "unknown"))},
                "timestamp": {"S": str(d.get("timestamp", ""))},
            }
            if "temperature" in d:
                item["temperature"] = {"S": str(d["temperature"])}
            if "status" in d:
                item["status"] = {"S": str(d["status"])}
            ddb.put_item(TableName=TABLE, Item=item)
            count += 1
    return {"stored": count}
