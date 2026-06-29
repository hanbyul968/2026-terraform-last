"""
module1 - Workflow Lambda (ap-southeast-1)
학생 성적 CSV 처리: 평균/등급 계산 -> DynamoDB 저장, 원본 -> /processed/,
검증 실패 행 -> /error/error_<timestamp>_<studentId>.json

환경변수:
  S3_BUCKET : wsc2026-student-score-bucket-<비번호>
  DDB_TABLE : wsc2026-student-score

입력(event):
  Step Functions 가 전달하는 EventBridge "Object Created" 이벤트 또는
  {"bucket": "...", "key": "input/xxx.csv"} 형태를 모두 허용한다.

CSV 헤더(예): studentId,examDate,name,korean,english,math,science,social
"""
import csv
import io
import json
import os
import time

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
DDB_TABLE = os.environ["DDB_TABLE"]

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")

SUBJECTS = ["korean", "english", "math", "science", "social"]


def _resolve_key(event):
    """다양한 입력 형태에서 (bucket, key) 추출."""
    if isinstance(event, dict):
        detail = event.get("detail")
        if isinstance(detail, dict):
            b = detail.get("bucket", {}).get("name")
            k = detail.get("object", {}).get("key")
            if b and k:
                return b, k
        if event.get("bucket") and event.get("key"):
            return event["bucket"], event["key"]
        records = event.get("Records")
        if records:
            r = records[0]["s3"]
            return r["bucket"]["name"], r["object"]["key"]
    return S3_BUCKET, "input/test.csv"


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


def _write_error(reason, raw_row, student_id):
    ts = int(time.time() * 1000)
    sid = student_id if student_id else "unknown"
    body = json.dumps(
        {"reason": reason, "row": raw_row, "studentId": sid, "timestamp": ts},
        ensure_ascii=False,
    )
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=f"error/error_{ts}_{sid}.json",
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )


def lambda_handler(event, context):
    bucket, key = _resolve_key(event)

    obj = s3.get_object(Bucket=bucket, Key=key)
    text = obj["Body"].read().decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))

    processed, errored = 0, 0
    for row in reader:
        sid = (row.get("studentId") or "").strip()
        exam = (row.get("examDate") or "").strip()
        try:
            if not sid or not exam:
                raise ValueError("missing studentId/examDate")
            scores = {}
            for s in SUBJECTS:
                scores[s] = float(row[s])
                if scores[s] < 0 or scores[s] > 100:
                    raise ValueError(f"score out of range: {s}")
            avg = round(sum(scores.values()) / len(SUBJECTS), 1)
            item = {
                "studentId": {"S": sid},
                "examDate": {"S": exam},
                "name": {"S": (row.get("name") or "").strip()},
                "average": {"N": str(avg)},
                "grade": {"S": _grade(avg)},
            }
            for s in SUBJECTS:
                item[s] = {"N": str(scores[s])}
            ddb.put_item(TableName=DDB_TABLE, Item=item)
            processed += 1
        except Exception as exc:  # noqa: BLE001
            _write_error(str(exc), row, sid)
            errored += 1

    # 원본 파일을 /processed/ 로 복사
    filename = key.split("/")[-1]
    s3.copy_object(
        Bucket=S3_BUCKET,
        CopySource={"Bucket": bucket, "Key": key},
        Key=f"processed/{filename}",
    )

    return {"processed": processed, "errored": errored, "source": f"{bucket}/{key}"}
