#!/bin/bash
set -e

BOOTSTRAP="b-1.mskordercluster.hvcyyl.c2.kafka.ap-northeast-3.amazonaws.com:9092,b-2.mskordercluster.hvcyyl.c2.kafka.ap-northeast-3.amazonaws.com:9092"
BUCKET="wsc-msk-order-data-586639730662"
TOPIC="order-events"
KAFKA_HOME="/home/ec2-user/kafka_2.13-3.5.1"

echo "=== Installing Kafka & Java ==="
sudo dnf install -y java-11-amazon-corretto 2>/dev/null || true
if [ ! -d "/home/ec2-user/kafka_2.13-3.5.1" ]; then
  cd /home/ec2-user
  curl -sO https://archive.apache.org/dist/kafka/3.5.1/kafka_2.13-3.5.1.tgz
  tar -xzf kafka_2.13-3.5.1.tgz
  rm -f kafka_2.13-3.5.1.tgz
fi

echo "=== Creating Kafka topic ==="
$KAFKA_HOME/bin/kafka-topics.sh --create --topic $TOPIC --bootstrap-server $BOOTSTRAP --partitions 2 --replication-factor 2 2>/dev/null || echo "Topic already exists"

echo "=== Verifying topic ==="
$KAFKA_HOME/bin/kafka-topics.sh --list --bootstrap-server $BOOTSTRAP

echo "=== Installing dependencies ==="
sudo dnf install -y python3-pip 2>/dev/null || true
pip3 install kafka-python-ng boto3 --quiet 2>/dev/null || sudo pip3 install kafka-python-ng boto3 --quiet

echo "=== Creating producer.py ==="
cat > /home/ec2-user/producer.py << 'PYEOF'
import argparse, json, os, random, time, uuid
from datetime import datetime, timezone
from kafka import KafkaProducer

PRODUCT_LIST = [
    {"id": "P001", "name": "무선 이어폰", "price": 89000},
    {"id": "P002", "name": "스마트워치", "price": 299000},
    {"id": "P003", "name": "노트북 파우치", "price": 35000},
    {"id": "P004", "name": "USB-C 허브", "price": 55000},
    {"id": "P005", "name": "기계식 키보드", "price": 145000},
]
REGIONS = ["seoul", "busan", "daegu", "incheon", "gwangju"]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-servers", required=True)
    parser.add_argument("--topic", default="order-events")
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--interval", type=float, default=0.5)
    args = parser.parse_args()

    producer = KafkaProducer(
        bootstrap_servers=args.bootstrap_servers.split(","),
        value_serializer=lambda v: json.dumps(v, ensure_ascii=False).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
        security_protocol="PLAINTEXT"
    )

    for i in range(args.count):
        product = random.choice(PRODUCT_LIST)
        quantity = random.randint(1, 5)
        order = {
            "orderId": str(uuid.uuid4()),
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "region": random.choice(REGIONS),
            "product": product,
            "quantity": quantity,
            "totalPrice": product["price"] * quantity,
            "status": "CREATED",
        }
        producer.send(args.topic, key=order["orderId"], value=order)
        print(f"[{i+1}/{args.count}] orderId={order['orderId']}")
        time.sleep(args.interval)

    producer.flush()
    producer.close()
    print(f"Done: {args.count} messages sent")

if __name__ == "__main__":
    main()
PYEOF

echo "=== Creating ec2_consumer.py ==="
cat > /home/ec2-user/ec2_consumer.py << 'PYEOF'
import argparse, json, os, uuid
from datetime import datetime, timezone
import boto3
from kafka import KafkaConsumer

def get_s3_key(timestamp_utc, filename):
    return f"orders/year={timestamp_utc.strftime('%Y')}/month={timestamp_utc.strftime('%m')}/day={timestamp_utc.strftime('%d')}/{filename}"

def upload_to_s3(s3_client, bucket, messages):
    if not messages:
        return True
    upload_time = datetime.now(timezone.utc)
    filename = f"orders_{uuid.uuid4().hex}.jsonl"
    s3_key = get_s3_key(upload_time, filename)
    body = "\n".join(json.dumps(msg, ensure_ascii=False) for msg in messages)
    s3_client.put_object(Bucket=bucket, Key=s3_key, Body=body.encode("utf-8"), ContentType="application/x-ndjson")
    print(f"[S3] s3://{bucket}/{s3_key} ({len(messages)} records)")
    return True

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-servers", required=True)
    parser.add_argument("--topic", default="order-events")
    parser.add_argument("--group-id", default="ec2-consumer-group")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--poll-timeout", type=int, default=5000)
    args = parser.parse_args()

    s3_client = boto3.client("s3", region_name="ap-northeast-3")
    consumer = KafkaConsumer(
        args.topic,
        bootstrap_servers=args.bootstrap_servers.split(","),
        group_id=args.group_id,
        value_deserializer=lambda v: json.loads(v.decode("utf-8")),
        enable_auto_commit=False,
        auto_offset_reset="earliest",
        security_protocol="PLAINTEXT"
    )

    batch = []
    total = 0
    try:
        while True:
            records = consumer.poll(timeout_ms=args.poll_timeout)
            if not records:
                if batch:
                    upload_to_s3(s3_client, args.bucket, batch)
                    consumer.commit()
                    total += len(batch)
                    batch = []
                continue
            for tp, messages in records.items():
                for msg in messages:
                    batch.append(msg.value)
                    if len(batch) >= args.batch_size:
                        upload_to_s3(s3_client, args.bucket, batch)
                        consumer.commit()
                        total += len(batch)
                        batch = []
    except KeyboardInterrupt:
        if batch:
            upload_to_s3(s3_client, args.bucket, batch)
            consumer.commit()
        print(f"Total: {total + len(batch)} records")
    finally:
        consumer.close()

if __name__ == "__main__":
    main()
PYEOF

echo "=== Running producer (50 messages) ==="
cd /home/ec2-user
python3 producer.py --bootstrap-servers $BOOTSTRAP --topic $TOPIC --count 50 --interval 0.2

echo "=== Running consumer (background, 30s) ==="
timeout 30 python3 ec2_consumer.py --bootstrap-servers $BOOTSTRAP --topic $TOPIC --bucket $BUCKET --batch-size 10 || true

echo "=== Verifying S3 ==="
aws s3 ls s3://$BUCKET/orders/ --recursive | head -5

echo "=== Done! ==="
