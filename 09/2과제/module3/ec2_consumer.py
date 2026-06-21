import argparse
import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from kafka import KafkaConsumer


def create_consumer(bootstrap_servers, topic, group_id, username=None, password=None):
    config = {
        "bootstrap_servers": bootstrap_servers.split(","),
        "group_id": group_id,
        "value_deserializer": lambda v: json.loads(v.decode("utf-8")),
        "key_deserializer": lambda k: k.decode("utf-8") if k else None,
        "enable_auto_commit": False,
        "auto_offset_reset": "earliest",
        "max_poll_records": 50,
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

    consumer = KafkaConsumer(**config)
    consumer.subscribe([topic])
    return consumer


def get_s3_key(timestamp_utc, filename):
    now = timestamp_utc
    year = now.strftime("%Y")
    month = now.strftime("%m")
    day = now.strftime("%d")
    return f"orders/year={year}/month={month}/day={day}/{filename}"


def upload_to_s3(s3_client, bucket, messages):
    if not messages:
        return True

    upload_time = datetime.now(timezone.utc)
    filename = f"orders_{uuid.uuid4().hex}.jsonl"
    s3_key = get_s3_key(upload_time, filename)
    body = "\n".join(json.dumps(msg, ensure_ascii=False) for msg in messages)

    try:
        s3_client.put_object(
            Bucket=bucket,
            Key=s3_key,
            Body=body.encode("utf-8"),
            ContentType="application/x-ndjson",
        )
        print(f"[S3] 업로드 완료: s3://{bucket}/{s3_key} ({len(messages)}건)")
        return True
    except Exception as e:
        print(f"[ERROR] S3 업로드 실패: {e}")
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-servers", required=True)
    parser.add_argument("--topic", default="order-events")
    parser.add_argument("--group-id", default="ec2-consumer-group")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--poll-timeout", type=int, default=5000)
    args = parser.parse_args()

    aws_region = os.environ.get("AWS_REGION", "ap-northeast-2")
    username = os.environ.get("KAFKA_USERNAME")
    password = os.environ.get("KAFKA_PASSWORD")

    s3_client = boto3.client("s3", region_name=aws_region)

    print(f"[EC2 Consumer] 시작 | 토픽: {args.topic} | 버킷: {args.bucket}")
    print(f"[EC2 Consumer] 배치 크기: {args.batch_size}건")

    consumer = create_consumer(
        args.bootstrap_servers, args.topic, args.group_id, username, password
    )

    batch = []
    total_processed = 0

    try:
        while True:
            records = consumer.poll(timeout_ms=args.poll_timeout)

            if not records:
                if batch:
                    success = upload_to_s3(s3_client, args.bucket, batch)
                    if success:
                        consumer.commit()
                        total_processed += len(batch)
                        batch = []
                continue

            for tp, messages in records.items():
                for msg in messages:
                    order = msg.value
                    print(f"[수신] offset={msg.offset} | orderId={order.get('orderId')} | region={order.get('region')}")
                    batch.append(order)

                    if len(batch) >= args.batch_size:
                        success = upload_to_s3(s3_client, args.bucket, batch)
                        if success:
                            consumer.commit()
                            total_processed += len(batch)
                            batch = []
                        else:
                            print("[WARN] S3 업로드 실패 - offset 커밋 건너뜀")

    except KeyboardInterrupt:
        print(f"\n[종료] 총 처리: {total_processed}건")
    finally:
        if batch:
            success = upload_to_s3(s3_client, args.bucket, batch)
            if success:
                consumer.commit()
        consumer.close()


if __name__ == "__main__":
    main()