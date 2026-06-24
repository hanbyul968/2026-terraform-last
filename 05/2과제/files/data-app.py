import itertools
import json
import random
import time
from pathlib import Path

from kafka import KafkaProducer

LOG_PATH           = Path("/var/log/app/orders.log")
BATCH_SIZE         = 10
MAX_LOGS           = 10_000
KAFKA_BROKER       = "localhost:9092"
KAFKA_TOPIC        = "order-logs"
RANDOM_SEED        = 42
BASE_EVENT_TIME_MS = 1_704_067_200_000

NORMAL_USERS     = [f"user-{i:04d}" for i in range(1, 41)]
BOT_USERS        = [f"user-{i:04d}" for i in range(41, 43)]
RATE_LIMIT_USERS = [f"user-{i:04d}" for i in range(43, 45)]

_normal_cycle = itertools.cycle(NORMAL_USERS)
_bot_cycle    = itertools.cycle(BOT_USERS)
_rate_cycle   = itertools.cycle(RATE_LIMIT_USERS)


def generate_log(user_id: str, event_time_ms: int) -> dict:
    if user_id in BOT_USERS:
        cart_age_seconds = random.randint(0, 2)
        status_code      = random.choices([200, 500], weights=[90, 10])[0]
        latency_ms       = random.randint(50, 200)
    elif user_id in RATE_LIMIT_USERS:
        cart_age_seconds = random.randint(5, 60)
        status_code      = random.choices([429, 200], weights=[70, 30])[0]
        latency_ms       = random.randint(100, 400)
    else:
        cart_age_seconds = random.randint(10, 600)
        status_code      = random.choices([200, 400, 500], weights=[85, 10, 5])[0]
        latency_ms       = (
            random.randint(500, 1500) if status_code == 500
            else random.randint(80, 500)
        )
    return {
        "order_id":         f"ord-{random.getrandbits(32):08x}",
        "user_id":          user_id,
        "cart_age_seconds": cart_age_seconds,
        "status_code":      status_code,
        "latency_ms":       latency_ms,
        "event_time":       event_time_ms,
    }


def main():
    random.seed(RANDOM_SEED)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BROKER,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        acks="all",
        retries=3,
    )

    total       = 0
    batch_index = 0
    with LOG_PATH.open("w") as f:
        for _ in range(MAX_LOGS // BATCH_SIZE):
            event_time_ms = BASE_EVENT_TIME_MS + batch_index * 100

            users = (
                [next(_normal_cycle) for _ in range(7)]
                + [next(_bot_cycle)   for _ in range(2)]
                + [next(_rate_cycle)  for _ in range(1)]
            )

            for user_id in users:
                log  = generate_log(user_id, event_time_ms)
                f.write(json.dumps(log, ensure_ascii=False) + "\n")
                f.flush()
                producer.send(KAFKA_TOPIC, value=log)
                total += 1

            producer.flush()
            batch_index += 1
            time.sleep(0.1)

    producer.close()
    print(f"[INFO] 완료: {total}건 → {LOG_PATH} + Kafka({KAFKA_TOPIC})")


if __name__ == "__main__":
    main()