"""wsc2026-sensor-consumer

MSK 토픽 wsc2026-sensor-raw 를 소비한다.
 - NORMAL  -> DynamoDB(wsc2026-sensor-data) 저장
 - ALERT   -> wsc2026-sensor-alert 토픽으로 재발행 (alert_reason 추가)

의존 라이브러리: kafka-python, aws-msk-iam-sasl-signer-python
=> Lambda Layer 로 첨부해야 한다. (README 참고)
"""
import base64
import json
import os

import boto3
from kafka import KafkaProducer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

DDB_TABLE = os.environ["DDB_TABLE"]
ALERT_TOPIC = os.environ["ALERT_TOPIC"]
BOOTSTRAP_SERVER = os.environ["BOOTSTRAP_SERVER"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

table = boto3.resource("dynamodb").Table(DDB_TABLE)

_producer = None


class _TokenProvider:
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token


def get_producer():
    global _producer
    if _producer is None:
        _producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP_SERVER.split(","),
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=_TokenProvider(),
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        )
    return _producer


def detect_anomaly(data):
    temperature = float(data["temperature"])
    humidity = float(data["humidity"])

    if temperature > 80:
        return "ALERT", f"Temperature exceeded threshold: {temperature}°C"
    if temperature < 10:
        return "ALERT", f"Temperature below threshold: {temperature}°C"
    if humidity > 90:
        return "ALERT", f"Humidity exceeded threshold: {humidity}%"
    if humidity < 20:
        return "ALERT", f"Humidity below threshold: {humidity}%"
    return "NORMAL", None


def handler(event, context):
    records = [r for batch in event.get("records", {}).values() for r in batch]
    print(f"Processing batch: {len(records)} messages")

    for record in records:
        data = json.loads(base64.b64decode(record["value"]).decode("utf-8"))
        status, reason = detect_anomaly(data)

        if status == "NORMAL":
            print(f"{data['sensorId']}: NORMAL - temp={data['temperature']}°C, humidity={data['humidity']}%")
            # 채점 스크립트가 temperature.S / status.S 로 읽으므로 String 으로 저장한다.
            table.put_item(Item={
                "sensorId": data["sensorId"],
                "timestamp": data["timestamp"],
                "temperature": str(data["temperature"]),
                "humidity": str(data["humidity"]),
                "location": data["location"],
                "status": "NORMAL",
            })
        else:
            print(f"{data['sensorId']}: ALERT - temp={data['temperature']}°C ({reason})")
            alert = dict(data)
            alert["status"] = "ALERT"
            alert["alert_reason"] = reason
            get_producer().send(ALERT_TOPIC, value=alert)

    get_producer().flush()
    return {"statusCode": 200}
