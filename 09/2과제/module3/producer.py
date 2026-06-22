import argparse
import json
import os
import random
import time
import uuid
from datetime import datetime, timezone

from kafka import KafkaProducer
from kafka.errors import KafkaError


PRODUCT_LIST = [
    {"id": "P001", "name": "무선 이어폰", "price": 89000},
    {"id": "P002", "name": "스마트워치", "price": 299000},
    {"id": "P003", "name": "노트북 파우치", "price": 35000},
    {"id": "P004", "name": "USB-C 허브", "price": 55000},
    {"id": "P005", "name": "기계식 키보드", "price": 145000},
]

REGIONS = ["seoul", "busan", "daegu", "incheon", "gwangju"]


def create_producer(bootstrap_servers, username=None, password=None):
    config = {
        "bootstrap_servers": bootstrap_servers.split(","),
        "value_serializer": lambda v: json.dumps(v, ensure_ascii=False).encode("utf-8"),
        "key_serializer": lambda k: k.encode("utf-8") if k else None,
        "acks": "all",
        "retries": 3,
        "retry_backoff_ms": 500,
    }

    if username and password:
        config.update({
            "security_protocol": "SASL_SSL",
            "sasl_mechanism": "SCRAM-SHA-512",
            "sasl_plain_username": username,
            "sasl_plain_password": password,
        })
    else:
        config["security_protocol"] = "PLAINTEXT"

    return KafkaProducer(**config)


def generate_order():
    product = random.choice(PRODUCT_LIST)
    quantity = random.randint(1, 5)

    return {
        "orderId": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "region": random.choice(REGIONS),
        "product": product,
        "quantity": quantity,
        "totalPrice": product["price"] * quantity,
        "status": "CREATED",
    }


def on_send_success(record_metadata):
    print(f"[OK] topic={record_metadata.topic} | partition={record_metadata.partition} | offset={record_metadata.offset}")


def on_send_error(ex):
    print(f"[ERROR] 메시지 전송 실패: {ex}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-servers", required=True)
    parser.add_argument("--topic", default="order-events")
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--interval", type=float, default=0.5)
    args = parser.parse_args()

    username = os.environ.get("KAFKA_USERNAME")
    password = os.environ.get("KAFKA_PASSWORD")

    print(f"[Producer] MSK 연결 중: {args.bootstrap_servers}")
    print(f"[Producer] 토픽: {args.topic} | 발행 수: {args.count}건")

    producer = create_producer(args.bootstrap_servers, username, password)

    sent = 0
    failed = 0

    for i in range(args.count):
        order = generate_order()
        key = order["orderId"]

        try:
            future = producer.send(args.topic, key=key, value=order)
            future.add_callback(on_send_success).add_errback(on_send_error)
            sent += 1
            print(f"[{i+1}/{args.count}] 발행: orderId={order['orderId']} | region={order['region']}")
        except KafkaError as e:
            print(f"[ERROR] 전송 실패: {e}")
            failed += 1

        time.sleep(args.interval)

    producer.flush()
    producer.close()
    print(f"\n[완료] 성공: {sent}건 | 실패: {failed}건")


if __name__ == "__main__":
    main()