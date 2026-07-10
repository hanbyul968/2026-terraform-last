"""
Lambda@Edge - Origin Response
Function: wsc2026-resize / Runtime: python3.12 / Region: us-east-1

캐시 미스로 오리진(S3) 응답이 돌아올 때 실행된다.
  1) 쿼리스트링의 w, h 를 파싱
  2) S3 원본 이미지를 해당 크기로 리사이징
  3) 응답 본문(body)을 리사이징 결과로 교체
  4) 리사이징 결과를 s3://<BUCKET>/resized/{type}_{원본파일명}_{yyyyMMdd_HHmmss}.png 로 저장
     - 타임스탬프는 KST 기준

주의 (Lambda@Edge 제약):
  * 환경 변수 사용 불가 → BUCKET 을 아래에 하드코딩할 것
  * Lambda Layer 사용 불가 → Pillow 를 zip 패키지에 함께 넣어야 함
  * origin-response 는 타임아웃 최대 30초, 응답 본문 생성 한도 1MB
"""

import base64
import io
import os
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs

import boto3
from PIL import Image

# ★ 본인 비번호로 교체
BUCKET = "wsc2026-cdn-asset-<비번호>"
REGION = "us-east-1"

KST = timezone(timedelta(hours=9))
s3 = boto3.client("s3", region_name=REGION)


def handler(event, context):
    cf = event["Records"][0]["cf"]
    request = cf["request"]
    response = cf["response"]

    # 정상 응답이 아니면 그대로 통과
    if str(response.get("status")) != "200":
        return response

    params = parse_qs(request.get("querystring", ""))
    try:
        width = int(params["w"][0])
        height = int(params["h"][0])
    except (KeyError, ValueError, IndexError):
        return response

    device_type = params.get("type", ["desktop"])[0]

    key = request["uri"].lstrip("/")          # ex) origin/worldskills_banner.png
    if not key.startswith("origin/"):
        return response

    # 1) 원본 이미지 로드
    obj = s3.get_object(Bucket=BUCKET, Key=key)
    original = obj["Body"].read()

    # 2) 리사이징
    image = Image.open(io.BytesIO(original))
    if image.mode not in ("RGB", "RGBA"):
        image = image.convert("RGB")
    resized = image.resize((width, height), Image.LANCZOS)

    buffer = io.BytesIO()
    resized.save(buffer, format="PNG", optimize=True)
    payload = buffer.getvalue()

    # 3) resized/ 경로에 저장 (KST 타임스탬프)
    stem = os.path.splitext(os.path.basename(key))[0]   # worldskills_banner
    stamp = datetime.now(KST).strftime("%Y%m%d_%H%M%S")
    s3.put_object(
        Bucket=BUCKET,
        Key=f"resized/{device_type}_{stem}_{stamp}.png",
        Body=payload,
        ContentType="image/png",
    )

    # 4) 응답 본문 교체
    response["body"] = base64.b64encode(payload).decode("utf-8")
    response["bodyEncoding"] = "base64"
    response["headers"]["content-type"] = [
        {"key": "Content-Type", "value": "image/png"}
    ]
    # 원본 Content-Length 헤더가 남아 있으면 응답이 깨진다
    response["headers"].pop("content-length", None)

    return response
