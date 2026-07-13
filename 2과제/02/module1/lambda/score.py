import os
import csv
import io
import json
import boto3

s3 = boto3.client("s3")
ddb = boto3.resource("dynamodb")
TABLE = os.environ["TABLE_NAME"]


def _grade(avg):
    if avg >= 90:
        return "A"
    if avg >= 80:
        return "B"
    if avg >= 70:
        return "C"
    if avg >= 60:
        return "D"
    return "F"


def lambda_handler(event, context):
    # event: {"bucket": "...", "key": "input/xxx.csv"}
    bucket = event["bucket"]
    key = event["key"]
    obj = s3.get_object(Bucket=bucket, Key=key)
    text = obj["Body"].read().decode("utf-8")
    table = ddb.Table(TABLE)
    subjects = ["korean", "english", "math", "science", "social"]
    count = 0
    reader = csv.DictReader(io.StringIO(text))
    for row in reader:
        scores = [int(row[s]) for s in subjects]
        avg = round(sum(scores) / len(scores), 2)
        item = {
            "studentId": row["studentId"],
            "examDate": row["examDate"],
            "name": row.get("name", ""),
            "average": avg,
            "grade": _grade(avg),
        }
        for s in subjects:
            item[s] = int(row[s])
        table.put_item(Item=item)
        count += 1
    return {"processed": count, "bucket": bucket, "key": key}
