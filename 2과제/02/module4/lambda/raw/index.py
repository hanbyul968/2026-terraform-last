import base64
import json
import logging
import os
from decimal import Decimal

import boto3
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DDB_TABLE = os.environ["DDB_TABLE"]
ALERT_TOPIC = os.environ["ALERT_TOPIC"]
BOOTSTRAP_SERVER = os.environ["BOOTSTRAP_SERVER"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(DDB_TABLE)
producer = None


class MSKTokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token


def _producer():
    global producer
    if producer is None:
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP_SERVER.split(","),
            security_protocol="SASL_SSL",
            sasl_mechanism="OAUTHBEARER",
            sasl_oauth_token_provider=MSKTokenProvider(),
            value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        )
    return producer


def _records(event):
    for messages in event.get("records", {}).values():
        for message in messages:
            yield json.loads(base64.b64decode(message["value"]).decode("utf-8"))


def _alert_reason(temperature, humidity):
    if temperature > 80:
        return f"Temperature exceeded threshold: {temperature}°C"
    if temperature < 10:
        return f"Temperature below threshold: {temperature}°C"
    if humidity > 90:
        return f"Humidity exceeded threshold: {humidity}%"
    if humidity < 20:
        return f"Humidity below threshold: {humidity}%"
    return None


def handler(event, context):
    records = list(_records(event))
    logger.info("Processing batch: %d messages", len(records))
    alert_producer = None
    normal_count = 0
    alert_count = 0

    for record in records:
        temperature = float(record["temperature"])
        humidity = float(record["humidity"])
        reason = _alert_reason(temperature, humidity)

        if reason:
            alert_record = dict(record)
            alert_record["status"] = "ALERT"
            alert_record["alert_reason"] = reason
            alert_producer = alert_producer or _producer()
            alert_producer.send(ALERT_TOPIC, alert_record)
            alert_count += 1
            logger.info(
                "%s: ALERT - temp=%s°C, humidity=%s%% (%s)",
                record.get("sensorId"),
                temperature,
                humidity,
                reason,
            )
            continue

        item = dict(record)
        item["temperature"] = Decimal(str(record["temperature"]))
        item["humidity"] = Decimal(str(record["humidity"]))
        item["status"] = "NORMAL"
        table.put_item(Item=item)
        normal_count += 1
        logger.info(
            "%s: NORMAL - temp=%s°C, humidity=%s%%",
            record.get("sensorId"),
            temperature,
            humidity,
        )

    if alert_producer is not None:
        alert_producer.flush()

    return {"processed": len(records), "normal": normal_count, "alerts": alert_count}
