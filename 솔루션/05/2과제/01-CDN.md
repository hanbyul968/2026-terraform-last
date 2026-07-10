# Module 1 — CDN (us-east-1)

> **리전 반드시 us-east-1** (Lambda@Edge는 us-east-1에서만 생성 가능)

## 구성 요약
```
브라우저 → CloudFront (/images) → [viewer-request: gj2026-cdn-request]
              ↓ origin = Lambda Function URL
         gj2026-cdn-rotate  → S3(images/dog.png) 읽어 회전 → PNG 반환
              ↓ [origin-response: gj2026-cdn-response]
         캐시 저장 (image, rotate 쿼리별로 분리)
```

| 항목 | 값 |
|---|---|
| S3 버킷 | `gj2026-cdn-bucket-101` |
| 이미지 prefix | `images/` |
| Origin Lambda | `gj2026-cdn-rotate` (Function URL, Auth NONE) |
| Lambda@Edge | `gj2026-cdn-request`, `gj2026-cdn-response` |
| Runtime | Python 3.14 |
| Behavior | `/images` |

---

## 1) S3 버킷 생성 + 이미지 업로드

**콘솔 → S3 → 버킷 만들기**
- 이름: `gj2026-cdn-bucket-101`
- 리전: **us-east-1**
- **퍼블릭 액세스 차단: 모두 체크(기본값 유지)** ← 과제 요구사항
- 생성

**버킷 → 업로드**
- 폴더 `images/` 만들고 그 안에 `dog.png` 업로드
- 최종 키: `images/dog.png`

---

## 2) Lambda 실행 역할 만들기

**콘솔 → IAM → 역할 → 역할 만들기**
- 신뢰할 수 있는 엔터티: **AWS 서비스** → **Lambda**
- 권한: `AWSLambdaBasicExecutionRole` 체크
- 역할 이름: `gj2026-cdn-lambda-role` → 생성

**생성 후 → 신뢰 관계 편집** (Lambda@Edge가 이 역할을 쓰려면 edgelambda 필요)
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": ["lambda.amazonaws.com", "edgelambda.amazonaws.com"] },
    "Action": "sts:AssumeRole"
  }]
}
```

**권한 추가 → 인라인 정책** (S3 읽기), 이름 `gj2026-cdn-s3`
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": "arn:aws:s3:::gj2026-cdn-bucket-101/*"
  }]
}
```

---

## 3) Origin Lambda (`gj2026-cdn-rotate`) — Pillow 필요

Pillow 라이브러리가 필요하므로 **CloudShell에서 zip을 만들어 업로드**합니다.

### CloudShell(us-east-1)에서 패키지 빌드
```bash
mkdir -p ~/rotate && cd ~/rotate
cat > rotate.py <<'EOF'
import boto3, base64, os, io
from PIL import Image

s3 = boto3.client("s3", region_name="us-east-1")
BUCKET = os.environ["BUCKET_NAME"]

def lambda_handler(event, context):
    qs = event.get("queryStringParameters") or {}
    image = qs.get("image", "dog")
    rotate = int(qs.get("rotate", 0))
    if not image.endswith(".png"):
        image = image + ".png"
    key = f"images/{image}"
    try:
        img_data = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except Exception as e:
        return {"statusCode": 404, "headers": {"Content-Type": "application/json"},
                "body": f'{{"error":"{e}"}}'}

    if rotate % 360 == 0:
        out = img_data                      # 원본 그대로 (채점 1-1 해시 일치)
    else:
        img = Image.open(io.BytesIO(img_data))
        img = img.rotate(-rotate, expand=True)   # 시계 방향
        buf = io.BytesIO(); img.save(buf, format="PNG"); out = buf.getvalue()

    return {"statusCode": 200,
            "headers": {"Content-Type": "image/png", "Cache-Control": "max-age=86400"},
            "body": base64.b64encode(out).decode(), "isBase64Encoded": True}
EOF

pip3 install --platform manylinux2014_x86_64 --target . \
  --implementation cp --python-version 3.14 --only-binary=:all: Pillow
zip -qr rotate.zip .
echo "생성됨: ~/rotate/rotate.zip"
```
> `--python-version 3.14`가 안 되면 Lambda 런타임과 맞춰 조정.

CloudShell 우상단 **Actions → Download file** 로 `rotate.zip` 다운로드 (또는 아래처럼 바로 배포).

### 콘솔 → Lambda → 함수 생성
- 이름: `gj2026-cdn-rotate`
- 런타임: **Python 3.14**
- 실행 역할: **기존 역할 사용** → `gj2026-cdn-lambda-role`
- 생성 후:
  - **코드 → .zip 업로드** → `rotate.zip`
  - **런타임 설정 → 핸들러**: `rotate.lambda_handler`
  - **구성 → 환경 변수**: `BUCKET_NAME = gj2026-cdn-bucket-101`
  - **구성 → 일반 구성**: 타임아웃 30초, 메모리 512MB

### Function URL 활성화
- **구성 → 함수 URL → 함수 URL 생성**
- 인증 유형: **NONE**
- ✅ **"Invoke 권한을 모든 사람에게 부여" 체크** (안 하면 403! 콘솔이 리소스 정책을 자동 추가)
- 생성 → URL 복사 (예: `https://xxxx.lambda-url.us-east-1.on.aws/`)

> CLI로 권한만 따로 줄 때:
> ```bash
> aws lambda add-permission --function-name gj2026-cdn-rotate --region us-east-1 \
>   --statement-id FunctionURLAllowPublicAccess \
>   --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE
> ```

### 동작 확인
```bash
curl -s "https://<함수URL호스트>/?image=dog&rotate=0" | sha256sum
# b9e2027f47e6697ea180bbec0e31e438515050bfbdebef720d3a7b65c58c1a2e 이어야 정답
```

---

## 4) Lambda@Edge 2개 만들기

**둘 다 us-east-1, 런타임 Python 3.14, 역할 `gj2026-cdn-lambda-role`, 타임아웃 5초**

### `gj2026-cdn-request` (viewer-request)
콘솔 → Lambda → 함수 생성 → 코드에 붙여넣고 **Deploy**
```python
def lambda_handler(event, context):
    request = event["Records"][0]["cf"]["request"]
    request["uri"] = "/"     # Function URL 루트로 전달 (쿼리스트링은 유지됨)
    return request
```

### `gj2026-cdn-response` (origin-response)
```python
def lambda_handler(event, context):
    response = event["Records"][0]["cf"]["response"]
    if "cache-control" not in response["headers"]:
        response["headers"]["cache-control"] = [
            {"key": "Cache-Control", "value": "max-age=86400"}
        ]
    return response
```

### 각 함수 버전 게시 (Lambda@Edge는 버전 필수)
각 함수에서 **작업 → 새 버전 게시** → 생성된 **버전 ARN(끝에 `:1`)** 복사해 둡니다.
```
arn:aws:lambda:us-east-1:<acct>:function:gj2026-cdn-request:1
arn:aws:lambda:us-east-1:<acct>:function:gj2026-cdn-response:1
```

---

## 5) CloudFront 캐시 정책 (쿼리별 캐시 분리)

**콘솔 → CloudFront → 정책 → 캐시 → 캐시 정책 생성**
- 이름: `gj2026-cdn-cache-policy`
- TTL: 최소 0 / 기본 86400 / 최대 31536000
- **쿼리 문자열: 포함 목록** → `image`, `rotate` 추가
- 헤더: 없음, 쿠키: 없음
- 생성

> 이게 있어야 `rotate=0`과 `rotate=90`이 **다른 캐시 키**가 됩니다 (채점 1-3).

---

## 6) CloudFront 배포 생성

**콘솔 → CloudFront → 배포 생성**

**오리진**
- 오리진 도메인: 함수 URL 호스트만 입력
  (예: `xxxx.lambda-url.us-east-1.on.aws` — `https://`와 끝 `/` 제외)
- 프로토콜: **HTTPS만**
- 이름(오리진 ID): `lambda-rotate`

**기본 캐시 동작**
- 뷰어 프로토콜: Redirect HTTP to HTTPS
- 허용 메서드: GET, HEAD
- 캐시 정책: `gj2026-cdn-cache-policy`

**설정**
- 설명(Comment): `gj2026-cdn` (나중에 찾기 쉬움)
- 배포 생성

### `/images` 동작(Behavior) 추가
배포 → **동작 → 동작 생성**
- 경로 패턴: `/images`
- 오리진: `lambda-rotate`
- 뷰어 프로토콜: Redirect HTTP to HTTPS
- 허용 메서드: GET, HEAD
- 캐시 정책: `gj2026-cdn-cache-policy`
- **함수 연결**
  - 뷰어 요청: **Lambda@Edge** → `arn:...:gj2026-cdn-request:1`
  - 오리진 응답: **Lambda@Edge** → `arn:...:gj2026-cdn-response:1`
- 저장

배포가 **Deployed** 될 때까지 대기(5~10분).

---

## 7) 채점 검증

CloudShell(us-east-1). 먼저 `sudo dnf install ImageMagick -y`

```bash
DOMAIN=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='gj2026-cdn'].DomainName | [0]" --output text)
DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='gj2026-cdn'].Id | [0]" --output text)

# 1-1 함수/URL + 해시
for fn in gj2026-cdn-rotate gj2026-cdn-request gj2026-cdn-response; do
  aws lambda get-function --function-name $fn --region us-east-1 --query 'Configuration.[FunctionName,Runtime,State]'
done
aws lambda get-function-url-config --function-name gj2026-cdn-rotate --region us-east-1 --query '[FunctionUrl,AuthType]'
EXPECTED="b9e2027f47e6697ea180bbec0e31e438515050bfbdebef720d3a7b65c58c1a2e"
ACTUAL=$(curl -s "https://$DOMAIN/images?image=dog&rotate=0" | sha256sum | cut -d' ' -f1)
[ "$ACTUAL" = "$EXPECTED" ] && echo "일치" || echo "불일치 ($ACTUAL)"

# 1-2 Edge 연결 확인
aws cloudfront get-distribution-config --id $DIST_ID \
  --query 'DistributionConfig.CacheBehaviors.Items[?PathPattern==`/images`].LambdaFunctionAssociations' | grep -o "gj2026-cdn-[a-z]*"

# 1-3 캐시 분리 (Miss → Hit → Miss)
curl -so /dev/null -w "rotate=0 1st: %header{x-cache}\n"  "https://$DOMAIN/images?image=dog&rotate=0"
curl -so /dev/null -w "rotate=0 2nd: %header{x-cache}\n"  "https://$DOMAIN/images?image=dog&rotate=0"
curl -so /dev/null -w "rotate=90 1st: %header{x-cache}\n" "https://$DOMAIN/images?image=dog&rotate=90"

# 1-4 응답시간 (1st ≤3s Miss, 2nd ≤0.05s Hit)
curl -so /dev/null -w "1st: %{time_total}s | %header{x-cache}\n" "https://$DOMAIN/images?image=dog&rotate=180"
curl -so /dev/null -w "2nd: %{time_total}s | %header{x-cache}\n" "https://$DOMAIN/images?image=dog&rotate=180"

# 1-5 회전 무손실 (diff 0)
curl -s "https://$DOMAIN/images?image=dog&rotate=0"   > /tmp/orig.png
curl -s "https://$DOMAIN/images?image=dog&rotate=90"  | convert - -rotate -90 /tmp/r90.png
compare -metric MAE /tmp/orig.png /tmp/r90.png /dev/null 2>&1 | awk '{print "rotate=90 diff: "$1}'
curl -s "https://$DOMAIN/images?image=dog&rotate=180" | convert - -rotate 180 /tmp/r180.png
compare -metric MAE /tmp/orig.png /tmp/r180.png /dev/null 2>&1 | awk '{print "rotate=180 diff: "$1}'
```

---

## 자주 나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| Function URL 호출 시 **403** | Auth NONE인데 **리소스 정책 없음**. `add-permission`으로 `lambda:InvokeFunctionUrl`, principal `*`, auth-type NONE 추가 |
| 해시 불일치 (빈 응답 `e3b0c442…`) | 위 403 때문. 오리진이 에러라 CloudFront가 빈/에러 응답 |
| 해시 불일치 (이미지는 나옴) | `rotate=0`에서 Pillow로 **재인코딩**하면 바이트가 달라짐 → **원본 그대로 반환**해야 함 |
| `x-cache`가 계속 Miss | 캐시 정책 쿼리스트링 화이트리스트(`image`,`rotate`) 누락 |
| Lambda@Edge 연결 불가 | 버전(`:1`) ARN 아닌 `$LATEST`를 넣음. **버전 게시** 필요 |
| Edge 함수 삭제 안 됨 | CloudFront 배포 삭제 후 복제본 drain에 1~3시간 |
