# 모듈 2 — CDN Function (콘솔 솔루션)

**리전: `us-east-1` (버지니아 북부)** — CloudFront/CF Functions/KVS 는 글로벌이라 반드시 여기서.

엣지 A/B 테스팅: S3(OAC) + CloudFront + viewer-request/response Functions + KeyValueStore.

## 만들 리소스 요약
| 리소스 | 이름/값 |
|--------|---------|
| S3 | `skillsphone-landing-ab-<ACCOUNT_ID>` (Public Access 전면 차단) |
| KVS | `skillsphone-cdn-ab-config` (weight=0.3, version_a, version_b) |
| CF Function | `skillsphone-cdn-ab-req-fn` (viewer-request), `skillsphone-cdn-ab-res-fn` (viewer-response) |
| Cache Policy | `skillsphone-cdn-ab-cache-policy` (TTL 0/300/3600, 쿠키 whitelist x-sp-ab) |
| Distribution | `skillsphone-cdn-ab-distribution` (OAC, redirect-to-https) |

> 진행 순서 팁: **S3 → KVS → CF Functions → Cache/Response Policy → Distribution → S3 버킷 정책(OAC)** 순.
> Distribution 을 만들어야 그 ARN 으로 S3 버킷 정책을 잠글 수 있습니다.

---

## 1. S3 버킷 + HTML 업로드

콘솔 → **S3** → **버킷 만들기**
1. **버킷 이름**: `skillsphone-landing-ab-<ACCOUNT_ID>` (12자리 계정 ID 로 교체)
2. **리전**: us-east-1
3. **모든 퍼블릭 액세스 차단**: **켜짐(체크 유지)** ← BPA All True
4. 버킷 만들기.

### HTML 2개 업로드 (폴더 경로 주의)
1. 버킷 → **업로드** → **폴더 만들기** 대신, 업로드 시 **키 접두사**로 경로를 지정합니다.
2. 로컬에 `index.html` 두 개를 아래 내용으로 저장 후:
   - `version-a/index.html` 로 업로드 (업로드 화면에서 **대상**에 `version-a/` 지정하거나, 파일명을 폴더구조로)
   - `version-b/index.html` 로 업로드

**index_a.html:**
```html
<!DOCTYPE html>
<html lang="ko">
<head><meta charset="UTF-8"><title>SkillsPhone, Inc.</title></head>
<body>
  <div class="version-badge">version_a</div>
  <header><h1>SkillsPhone, Inc.</h1></header>
  <main><section class="card">
    <h2>스마트폰 앱, 더 쉽게</h2>
    <p>SkillsPhone은 일상에 필요한 모바일 앱을 설계하고 개발합니다.</p>
  </section></main>
  <footer>&copy; 2026 SkillsPhone, Inc.</footer>
</body>
</html>
```
**index_b.html:** 위와 동일하되 `version_a` → `version_b` 로 변경.

> 팁: 로컬에 `version-a` 폴더와 `version-b` 폴더를 만들고 각 폴더에 `index.html` 을 넣은 뒤,
> S3 업로드 화면에 **폴더째 드래그**하면 `version-a/index.html`, `version-b/index.html` 키로 올라갑니다.

> ✅ 채점 2-1: `version-a/index.html`, `version-b/index.html` 존재 + BPA All True.

---

## 2. KeyValueStore

콘솔 → **CloudFront** → 좌측 **Functions** → **KeyValueStores** → **Create KeyValueStore**
1. **Name**: `skillsphone-cdn-ab-config`
2. 생성 후 **Edit** 로 아래 3개 키 추가:

| Key | Value |
|-----|-------|
| `weight` | `0.3` |
| `version_a` | `/version-a/index.html` |
| `version_b` | `/version-b/index.html` |

3. 저장.

> ✅ 채점 2-2: KVS_KV version_a /version-a/index.html, version_b /version-b/index.html, weight 0.3

---

## 3. CloudFront Functions

콘솔 → **CloudFront** → **Functions** → **Create function**

### 3-1. viewer-request 함수
1. **Name**: `skillsphone-cdn-ab-req-fn`
2. **Runtime**: **cloudfront-js-2.0**
3. **Build** 탭 → 코드 붙여넣기:
```javascript
import cf from 'cloudfront';

const kvsHandle = cf.kvs();

async function handler(event) {
  var request = event.request;
  var cookies = request.cookies;

  var weightStr = await kvsHandle.get('weight');
  var weight = parseFloat(weightStr);
  var versionA = await kvsHandle.get('version_a');
  var versionB = await kvsHandle.get('version_b');

  if (cookies['x-sp-ab']) {
    var variant = cookies['x-sp-ab'].value;
    request.uri = variant === 'b' ? versionB : versionA;
  } else {
    var assigned = Math.random() < weight ? 'b' : 'a';
    request.uri = assigned === 'b' ? versionB : versionA;
    request.headers['x-sp-ab-assigned'] = { value: assigned };
  }
  return request;
}
```
4. **KeyValueStore 연결**: 함수 편집 화면의 **Associate KeyValueStore** →
   `skillsphone-cdn-ab-config` 선택.
5. **Save changes** → **Publish** 탭 → **Publish function** (LIVE 로 발행).

### 3-2. viewer-response 함수
1. **Create function** → **Name**: `skillsphone-cdn-ab-res-fn`, Runtime **cloudfront-js-2.0**
2. 코드:
```javascript
async function handler(event) {
  var response = event.response;
  var request = event.request;

  if (request.headers['x-sp-ab-assigned']) {
    var assigned = request.headers['x-sp-ab-assigned'].value;
    response.cookies['x-sp-ab'] = {
      value: assigned,
      attributes: 'Path=/; Max-Age=86400'
    };
  }
  return response;
}
```
3. **Save changes** → **Publish**. (KVS 연결 불필요)

> ✅ 채점 2-2: ReqFn ... DEPLOYED cloudfront-js-2.0 **true**(KVS연결), ResFn ... DEPLOYED cloudfront-js-2.0

---

## 4. OAC (Origin Access Control)

콘솔 → **CloudFront** → 좌측 **Security** → **Origin access** → **Create control setting**
1. **Name**: `skillsphone-landing-oac`
2. **Signing behavior**: Sign requests, **Origin type**: S3
3. 생성.

---

## 5. Cache Policy & Response Headers Policy

### 5-1. Cache Policy
콘솔 → **CloudFront** → **Policies** → **Cache** → **Create cache policy**
1. **Name**: `skillsphone-cdn-ab-cache-policy`
2. **TTL settings**: Minimum `0`, Default `300`, Maximum `3600`
3. **Cache key settings** → **Cookies**: **Include specified cookies** → `x-sp-ab` 추가
4. Headers: None, Query strings: None
5. 생성.

### 5-2. Response Headers Policy (Security Headers)
콘솔 → **Policies** → **Response headers** → **Create response headers policy**
1. **Name**: `skillsphone-cdn-ab-security-headers`
2. **Security headers** 섹션에서 필요한 항목 켜기 (X-Content-Type-Options,
   Frame-Options DENY, Referrer-Policy, Strict-Transport-Security, XSS-Protection)
3. 생성. (AWS Managed Policy 는 사용하지 않음)

> ✅ 채점 2-3: Cache Config ... whitelist x-sp-ab, Cache TTL 0 300 3600

---

## 6. CloudFront Distribution

콘솔 → **CloudFront** → **Distributions** → **Create distribution**
1. **Origin domain**: S3 버킷 `skillsphone-landing-ab-<ACCOUNT_ID>` 선택
2. **Origin access**: **Origin access control settings** → `skillsphone-landing-oac` 선택
   (안내 배너의 **버킷 정책 복사**는 나중에 7단계에서 적용)
3. **Default cache behavior**:
   - **Viewer protocol policy**: **Redirect HTTP to HTTPS**
   - **Cache policy**: `skillsphone-cdn-ab-cache-policy`
   - **Response headers policy**: `skillsphone-cdn-ab-security-headers`
   - **Function associations**:
     - Viewer request → **CloudFront Function** → `skillsphone-cdn-ab-req-fn`
     - Viewer response → **CloudFront Function** → `skillsphone-cdn-ab-res-fn`
4. **Default root object**: `index.html`
5. **Description/Comment**: `skillsphone-cdn-ab-distribution`  ← 채점이 Comment 로 찾음
6. **Price class**: Use all edge locations (Pay-as-you-go)
7. **Create distribution**. (배포 전파에 수 분 소요)

> ✅ 채점 2-3: ViewerProtocol redirect-to-https, OAC/CachePolicy true true,
> viewer-request/response 함수 연결.

---

## 7. S3 버킷 정책 (OAC 허용)

Distribution 생성 후 그 **ARN** 을 사용해 S3 버킷 정책을 작성합니다.

1. Distribution 상세에서 **ARN** 복사 (`arn:aws:cloudfront::<ACCOUNT_ID>:distribution/XXXX`)
2. 콘솔 → **S3** → 버킷 → **권한** → **버킷 정책** → 편집 → 아래 붙여넣기:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontOAC",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::skillsphone-landing-ab-<ACCOUNT_ID>/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DISTRIBUTION_ID>"
      }
    }
  }]
}
```
3. 저장.

> ✅ 채점 2-1: Policy Principal CF true, Policy Source ARN CF true

---

## 8. 검증 (채점 기준)

```bash
DOMAIN=$(aws cloudfront list-distributions --region us-east-1 \
  --query "DistributionList.Items[?Comment=='skillsphone-cdn-ab-distribution'].DomainName" --output text)

# 2-4 쿠키 강제: a→version_a, b→version_b, set-cookie 없음
for v in a b; do
  R=$(curl -sim10 -b x-sp-ab=$v "https://$DOMAIN/?_$RANDOM")
  grep -q "version_$v" <<<"$R" && echo "body_$v true" || echo "body_$v false"
done

# 2-5 최초 방문: 무작위 a/b 할당 + Set-Cookie(Max-Age=86400; Path=/)
curl -si "https://$DOMAIN/?_=$(date +%s%N)" | grep -i set-cookie
```

**2-6 (KVS 동적 반영, 콘솔 확인 어려우면 CLI)**: weight 를 1.0 으로 바꾸면 항상 version-b,
0.0 이면 version-a 로 라우팅됨. 확인 후 반드시 **0.3 으로 복원**.
```bash
KVS=$(aws cloudfront list-key-value-stores --region us-east-1 | jq -r \
  '.KeyValueStoreList.Items[]|select(.Name=="skillsphone-cdn-ab-config")|.ARN')
# 콘솔 KeyValueStores 편집 화면에서 weight 값을 1.0 / 0.0 로 바꿔가며 테스트 후 0.3 복원
```

> ✅ 정답: weight_1_uri /version-b/index.html, weight_0_uri /version-a/index.html, weight_restored 0.3
