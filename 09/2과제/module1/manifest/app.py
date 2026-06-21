import os
import time
import boto3

QUEUE_URL = os.environ["QUEUE_URL"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

sqs = boto3.client("sqs", region_name=REGION)


def process(message_body: str) -> None:
    deadline = time.time() + 60.0
    while time.time() < deadline:
        pass


def main():
    while True:
        resp = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for m in resp.get("Messages", []):
            process(m.get("Body", ""))
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])


if __name__ == "__main__":
    main()
