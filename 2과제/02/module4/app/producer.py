"""module4 - 센서 데이터 Producer (MSK IAM 인증)
  - wsc2026-sensor-raw 토픽에 센서 데이터를 주기적으로 발행
  - 이상치(temperature > 임계치 또는 status != NORMAL)는 wsc2026-sensor-alert 토픽에도 발행
환경변수:
  BOOTSTRAP : MSK IAM bootstrap brokers (host:9098,...)
"""
import datetime
import json
import os
import random
import time

from kafka import KafkaProducer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

BOOTSTRAP = os.environ.get("BOOTSTRAP", "localhost:9098")
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
RAW_TOPIC = "wsc2026-sensor-raw"
ALERT_TOPIC = "wsc2026-sensor-alert"


class Provider:
    def token(self):
        t, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return t


def _producer():
    return KafkaProducer(
        bootstrap_servers=BOOTSTRAP.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=Provider(),
        value_serializer=lambda v: json.dumps(v, separators=(",", ":")).encode("utf-8"),
    )


def _now():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime(
        "%Y-%m-%dT%H:%M:%S%z"
    )


def main():
    producer = _producer()
    while True:
        temp = round(random.uniform(20.0, 90.0), 1)
        status = "NORMAL" if temp < 80.0 else "ANOMALY"
        rec = {
            "sensorId": f"SENSOR-{random.randint(1, 5):03d}",
            "timestamp": _now(),
            "temperature": str(temp),
            "status": status,
        }
        producer.send(RAW_TOPIC, rec)
        if status != "NORMAL":
            producer.send(ALERT_TOPIC, rec)
        producer.flush()
        time.sleep(2)


if __name__ == "__main__":
    main()
