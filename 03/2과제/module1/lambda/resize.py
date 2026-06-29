import json
import os
import datetime
from io import BytesIO
from urllib.parse import parse_qs

import boto3
from PIL import Image

s3 = boto3.client("s3")


def lambda_handler(event, context):
    rec = event["Records"][0]["cf"]
    request = rec["request"]
    response = rec["response"]

    qs = parse_qs(request.get("querystring", ""))
    w = int(qs.get("w", ["1920"])[0])
    h = int(qs.get("h", ["1080"])[0])
    dtype = qs.get("type", ["desktop"])[0]

    # S3 오리진 도메인/버킷 추출
    domain = request["origin"]["s3"]["domainName"]
    bucket = domain.split(".s3")[0]
    uri = request["uri"]  # /origin/<file> 형태 가정
    key = uri.lstrip("/")
    fname = os.path.basename(key)
    base, _ext = os.path.splitext(fname)

    obj = s3.get_object(Bucket=bucket, Key=key)
    img = Image.open(BytesIO(obj["Body"].read())).convert("RGB")
    img = img.resize((w, h))
    out = BytesIO()
    img.save(out, format="PNG")
    out.seek(0)

    kst = datetime.timezone(datetime.timedelta(hours=9))
    ts = datetime.datetime.now(kst).strftime("%Y%m%d_%H%M%S")
    resized_key = f"resized/{dtype}_{base}_{ts}.png"
    s3.put_object(Bucket=bucket, Key=resized_key, Body=out.getvalue(), ContentType="image/png")

    import base64
    response["status"] = "200"
    response["statusDescription"] = "OK"
    response["headers"]["content-type"] = [{"key": "Content-Type", "value": "image/png"}]
    response["body"] = base64.b64encode(out.getvalue()).decode()
    response["bodyEncoding"] = "base64"
    return response
