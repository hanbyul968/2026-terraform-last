# 🏆 WSC2026 제2과제 — AWS 콘솔 풀이 (처음부터 끝까지)

> 제61회 인천기능경기대회 `과제지_vf` + `채점기준표_vf` 기준 **콘솔 클릭 순서** 가이드.
> 문서 안의 `<비번호>`, `<ACCOUNT_ID>`, `<ALB-DNS>` 등은 본인 값으로 바꿔 입력한다.

## ⚠️ 모듈마다 리전이 다르다 — 제일 많이 틀리는 부분

| 모듈 | 주제 | 리전 | 배점 |
|:-:|---|---|:-:|
| 1 | CDN | **버지니아 북부 `us-east-1`** | 7.5 |
| 2 | Keycloak | **서울 `ap-northeast-2`** | 7.5 |
| 3 | Container Logging | **도쿄 `ap-northeast-1`** | 7.5 |
| 4 | Workflow | **싱가포르 `ap-southeast-1`** | 7.5 |
| | | **합계** | **30** |

## 📋 세부 배점 체크리스트

| 모듈 | # | 세부 항목 | 배점 | ☐ |
|:-:|:-:|---|:-:|:-:|
| 1 | 1-1 | S3 Bucket | 0.5 | ☐ |
| 1 | 1-2 | CloudFront Distribution | 1.0 | ☐ |
| 1 | 1-3 | CloudFront Functions | 1.5 | ☐ |
| 1 | 1-4 | CloudFront Functions Associate | 1.5 | ☐ |
| 1 | 1-5 | Lambda@Edge | 1.5 | ☐ |
| 1 | 1-6 | Resizing (E2E) | 1.5 | ☐ |
| 2 | 2-1 | VPC | 0.5 | ☐ |
| 2 | 2-2 | Keycloak Server | 1.0 | ☐ |
| 2 | 2-3 | Keycloak ALB | 1.5 | ☐ |
| 2 | 2-4 | Keycloak Setting | 1.5 | ☐ |
| 2 | 2-5 | AWS IAM | 1.5 | ☐ |
| 2 | 2-6 | Keycloak SAML (수동) | 1.5 | ☐ |
| 3 | 3-1 | Application Running | 0.5 | ☐ |
| 3 | 3-2 | Fluentbit Pod | 1.0 | ☐ |
| 3 | 3-3 | Otel Pod | 1.0 | ☐ |
| 3 | 3-4 | Loki Pod | 1.0 | ☐ |
| 3 | 3-5 | Prometheus Pod | 1.0 | ☐ |
| 3 | 3-6 | Datasource | 1.5 | ☐ |
| 3 | 3-7 | Grafana dashboard (수동) | 1.5 | ☐ |
| 4 | 4-1 | S3 Bucket | 0.5 | ☐ |
| 4 | 4-2 | DynamoDB | 1.0 | ☐ |
| 4 | 4-3 | Lambda Functions | 1.5 | ☐ |
| 4 | 4-4 | Lambda Invoke | 1.5 | ☐ |
| 4 | 4-5 | State Machine | 1.5 | ☐ |
| 4 | 4-6 | Step Function E2E | 1.5 | ☐ |

## 🧰 준비물

- AWS 콘솔 로그인 (관리자급)
- **CloudShell** — 채점 스크립트(`mark.sh`) 실행 위치이자, 이 가이드의 CLI 보조 명령 실행 위치
- 배포파일 → 전부 [`files/`](files) 에 복사해 뒀다

| 경로 | 내용 |
|---|---|
| [`files/module1/`](files/module1) | `worldskills_banner.png`, CF Function 2개, Lambda@Edge 코드, IAM 정책, 패키징 스크립트 |
| [`files/module2/`](files/module2) | Keycloak user-data, SAML 신뢰정책, dev/infra IAM 정책 |
| [`files/module3/`](files/module3) | `deployment.yaml`, Helm values 4개, Grafana 대시보드 JSON |
| [`files/module4/`](files/module4) | `sample-orders.json`, `inventory-seed.json`, Lambda 2개, Step Functions ASL |

## ⏱️ 4시간 권장 순서

EKS 클러스터 생성(15~20분)과 CloudFront 배포 전파(5~15분)가 가장 오래 걸린다.
**모듈 3의 EKS 생성을 제일 먼저 걸어두고**, 기다리는 동안 다른 모듈을 진행하는 것이 유리하다.

```
0:00  M3 VPC + EKS 클러스터 생성 시작 ──────────┐ (백그라운드 ~20분)
0:20  M1 S3 → CloudFront 배포 생성 시작 ────┐  │ (백그라운드 ~10분)
0:30  M4 전체 (S3/DynamoDB/Lambda/SFn)     │  │
1:20  M1 Function/Lambda@Edge 연결 ◄───────┘  │
1:50  M2 VPC/EC2/ALB/Keycloak/IAM             │
3:00  M3 Helm 설치 + 대시보드 ◄───────────────┘
3:40  전체 mark.sh 재확인 · 부하 중지
```

---

# 1️⃣ CDN — 7.5점  `us-east-1`

> **리전 선택기를 `US East (N. Virginia)` 로 바꾸고 시작한다.**

디바이스(모바일/데스크탑)를 감지해 크기가 다른 이미지를 내려주는 CDN.
요청이 흐르는 순서를 먼저 이해하면 나머지는 조립이다.

```
브라우저
  │  ① viewer-request  : wsc2026-device-detect (CF Function)
  │       └ UA 보고 ?w=480&h=320&type=mobile 삽입
  ▼
CloudFront (wsc2026-cdn)
  │  캐시 미스면 오리진으로
  ▼
S3 (wsc2026-cdn-asset-<비번호>)  ← OAC 로만 접근 허용
  │  ② origin-response : wsc2026-resize (Lambda@Edge)
  │       └ w/h 로 리사이징 → 응답 본문 교체 + resized/ 에 저장
  ▼
  │  ③ viewer-response : wsc2026-response-header (CF Function)
  │       └ X-Device-Type, X-Resized 헤더 추가
  ▼
브라우저
```

## 1-1. S3 버킷 — 0.5점

`S3 → Create bucket`

| 항목 | 값 |
|---|---|
| Bucket name | `wsc2026-cdn-asset-<비번호>` |
| Region | US East (N. Virginia) |
| Block *all* public access | ✔ **체크 유지** |
| Bucket Versioning | **Enable** |

생성 후 `Objects → Create folder` 로 `origin/` 을 만들고,
`files/module1/worldskills_banner.png` 를 **`origin/` 안에** 업로드한다.

> 📌 **채점(1-1)**: 버킷명 · `Enabled` · public access block 4개 전부 `True` · `origin/worldskills_banner.png` 존재.

## 1-2. CloudFront 배포 — 1.0점

### (1) 캐시 정책 먼저 만들기

`CloudFront → Policies → Cache → Create cache policy`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-cache-policy` |
| TTL | Min 1 / Default 86400 / Max 31536000 |
| **Query strings** | **All** ← 이게 핵심. 디바이스별로 캐시가 분리된다 |
| Headers | None |
| Cookies | None |

### (2) 오리진 요청 정책

`Policies → Origin request → Create origin request policy`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-origin-policy` |
| **Query strings** | **All** ← Lambda@Edge 가 w/h 를 읽으려면 필수 |
| Headers | None |
| Cookies | None |

### (3) 배포 생성

`CloudFront → Distributions → Create distribution`

| 항목 | 값 |
|---|---|
| Origin domain | `wsc2026-cdn-asset-<비번호>.s3.us-east-1.amazonaws.com` |
| Origin access | **Origin access control settings (recommended)** |
| → Create new OAC | 이름 기본값, Sign requests |
| Viewer protocol policy | **Redirect HTTP to HTTPS** |
| Allowed HTTP methods | GET, HEAD |
| Cache policy | `wsc2026-cache-policy` |
| Origin request policy | `wsc2026-origin-policy` |
| **Price class** | **Use all edge locations (best performance)** ← `PriceClass_All` |
| WAF | Do not enable |

생성 직후 파란 배너의 **`Copy policy` → `Go to S3 bucket permissions`** 를 눌러
S3 버킷 정책에 CloudFront 서비스 프린시펄 접근 허용 정책을 붙여넣는다.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontServicePrincipal",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::wsc2026-cdn-asset-<비번호>/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"
      }
    }
  }]
}
```

### (4) ⭐ Name 태그 — 빠뜨리면 1-2 이후 채점이 전부 실패한다

CloudFront 배포에는 "이름" 필드가 없다. 채점 스크립트는 **태그**로 배포를 찾는다.

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Name,Values=wsc2026-cdn ...
```

`Distribution → Tags 탭 → Manage tags` 에서 `Name = wsc2026-cdn` 추가.
(배포 생성 마법사 마지막 단계에서 미리 넣어도 된다.)

> 📌 **채점(1-2)**: 도메인 출력 · Origin DomainName · `PriceClass_All`.

## 1-3. CloudFront Functions 2개 — 1.5점

`CloudFront → Functions → Create function`

**① `wsc2026-device-detect`** — Runtime `cloudfront-js-2.0`
코드는 [`files/module1/wsc2026-device-detect.js`](files/module1/wsc2026-device-detect.js) 붙여넣기.

**② `wsc2026-response-header`** — Runtime `cloudfront-js-2.0`
코드는 [`files/module1/wsc2026-response-header.js`](files/module1/wsc2026-response-header.js) 붙여넣기.

각각 `Save changes → Publish 탭 → Publish function` 까지 해야 **LIVE** 가 된다.

> 💡 `CloudFront-Is-Mobile-Viewer` 헤더는 캐시/오리진 정책에 헤더를 포함시켜야 함수에 도달하므로,
> 여기서는 과제지가 허용한 **User-Agent 방식**으로 판별한다. 채점 스크립트도 `curl -A` 로 UA 를 바꿔 테스트한다.

> 📌 **채점(1-3)**: 두 함수 모두 Stage 가 `LIVE`.

## 1-4. Functions 연결 — 1.5점

`Distribution → Behaviors → Default (*) → Edit → 맨 아래 Function associations`

| Event type | Function type | Function |
|---|---|---|
| Viewer request | CloudFront Functions | `wsc2026-device-detect` |
| Viewer response | CloudFront Functions | `wsc2026-response-header` |

> ⚠️ Publish 하지 않은 함수는 목록에 뜨지 않는다. 1-3 을 먼저 끝낼 것.

## 1-5. Lambda@Edge — 1.5점

### (1) IAM 정책 · 역할

`IAM → Policies → Create policy → JSON`
→ [`files/module1/wsc2026-resize-policy.json`](files/module1/wsc2026-resize-policy.json) 붙여넣기 (버킷명 치환)
→ 이름 **`wsc2026-resize-policy`**

`IAM → Roles → Create role → Custom trust policy`
→ [`files/module1/trust-policy.json`](files/module1/trust-policy.json) 붙여넣기

```json
"Service": ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
```

> ⚠️ `edgelambda.amazonaws.com` 이 없으면 Lambda@Edge 배포 자체가 거부된다.

권한에서 위 `wsc2026-resize-policy` 를 **연결(attach)** → 이름 **`wsc2026-resize-role`**

> 📌 채점 스크립트가 `aws iam list-attached-role-policies` 를 쓰므로,
> **인라인 정책이 아니라 관리형 정책으로 붙여야** `wsc2026-resize-policy` 가 출력된다.
> Administrator 등 과도한 정책은 금지(최소 권한).

### (2) 배포 패키지 (Pillow 포함)

**Lambda@Edge 는 Layer 를 쓸 수 없다.** Pillow 를 zip 안에 넣어야 한다.
CloudShell(us-east-1) 에서:

```bash
mkdir -p ~/resize && cd ~/resize
# lambda_function.py 를 여기에 두고 (BUCKET 변수를 본인 버킷명으로 수정)
bash build-package.sh          # files/module1/build-package.sh
```

### (3) 함수 생성

`Lambda → Create function` (리전 = **us-east-1**)

| 항목 | 값 |
|---|---|
| Function name | `wsc2026-resize` |
| Runtime | **Python 3.12** |
| Architecture | **x86_64** |
| Execution role | Use an existing role → `wsc2026-resize-role` |

- `Code → Upload from → .zip file` 로 `wsc2026-resize.zip` 업로드
- `Runtime settings → Edit → Handler` = **`lambda_function.handler`**
- `Configuration → General → Edit`
  - Memory **512 MB** (이상)
  - **Timeout `30` 초** ← origin-response 는 30초가 상한. 넘기면 배포 불가
- **환경 변수 사용 금지** (Lambda@Edge 제약) → 코드의 `BUCKET` 상수를 직접 수정

### (4) 버전 발행 후 연결

Lambda@Edge 는 `$LATEST` 를 못 쓴다. **버전을 발행**해야 한다.

`Lambda → wsc2026-resize → Versions → Publish new version`
→ `Actions → Deploy to Lambda@Edge`

| 항목 | 값 |
|---|---|
| Distribution | `wsc2026-cdn` |
| Cache behavior | `*` |
| **CloudFront event** | **Origin response** |
| Include body | 체크 안 함 |

> 📌 **채점(1-5)**: `wsc2026-resize` + `python3.12` / 역할 `wsc2026-resize-role` + 정책 `wsc2026-resize-policy` /
> `origin-response` 에 `...:function:wsc2026-resize:<Version>` 연결.

## 1-6. 동작 확인 (Resizing) — 1.5점

배포 상태가 `Deploying` → 공백(완료)이 될 때까지 기다린 뒤(5~15분), CloudShell 에서:

```bash
CF_DOMAIN=<배포 도메인>.cloudfront.net
BUST=$(date +%s)

# 모바일 UA
curl -s -o /tmp/m.png -D /tmp/m.txt \
  -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" \
  "https://$CF_DOMAIN/origin/worldskills_banner.png?w=480&h=320&type=mobile&bust=$BUST"
grep -i -e x-device-type -e x-resized /tmp/m.txt   # mobile / true

# 데스크탑 UA
curl -s -o /tmp/d.png -D /tmp/d.txt \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0" \
  "https://$CF_DOMAIN/origin/worldskills_banner.png?w=1920&h=1080&type=desktop&bust=$BUST"

aws s3 ls s3://wsc2026-cdn-asset-<비번호>/resized/
```

체크 포인트:
- `resized/mobile_worldskills_banner_YYYYMMDD_HHMMSS.png` 가 **KST 현재 시각(±5분)** 으로 생성
- 응답 헤더 `X-Device-Type`, `X-Resized: true`
- 모바일/데스크탑 응답 바이트 수가 서로 다름

> 🔧 **안 되면**: `bust` 쿼리로 캐시를 우회했는지 확인 → CloudWatch Logs 는
> **엣지 로케이션 리전**(예: `ap-northeast-2`)의 `/aws/lambda/us-east-1.wsc2026-resize` 로그 그룹에 쌓인다.

---

# 2️⃣ Keycloak SAML SSO — 7.5점  `ap-northeast-2`

> **리전을 `서울(ap-northeast-2)` 로 변경.**

```
사용자 ── ALB(:80) ── EC2(private, :8080) Keycloak
                              │
                     SAML 2.0 Assertion
                              ▼
                    AWS IAM SAML Provider
                     ├ dev-team  → wsc2026-dev-role   (서울 EC2/S3 읽기)
                     └ infra-team→ wsc2026-infra-role (전체 읽기 + EC2 시작/중지)
```

## 2-1. VPC — 0.5점

`VPC → Create VPC → VPC only`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-keycloak-vpc` |
| IPv4 CIDR | `10.20.0.0/16` |

생성 후 `Actions → Edit VPC settings` → **Enable DNS hostnames** ✔

### 서브넷 3개 (`VPC → Subnets → Create subnet`)

| Name | CIDR | AZ |
|---|---|---|
| `wsc2026-public-subnet-a` | `10.20.1.0/24` | `ap-northeast-2a` |
| `wsc2026-public-subnet-b` | `10.20.2.0/24` | `ap-northeast-2b` |
| `wsc2026-private-subnet-a` | `10.20.10.0/24` | `ap-northeast-2a` |

두 퍼블릭 서브넷은 `Actions → Edit subnet settings → Enable auto-assign public IPv4` ✔

### IGW / NAT / 라우팅

1. `Internet gateways → Create` → `wsc2026-keycloak-igw` → VPC 에 Attach
2. `NAT gateways → Create` → 이름 `wsc2026-keycloak-nat`, Subnet = **public-subnet-a**, Elastic IP 할당
   → 프라이빗 EC2 가 docker/keycloak 이미지를 받으려면 필요하다
3. `Route tables → Create`
   - `wsc2026-public-rt` : `0.0.0.0/0 → igw` , 서브넷 연결 = public a, b
   - `wsc2026-private-rt` : `0.0.0.0/0 → nat` , 서브넷 연결 = private a

> 📌 **채점(2-1)**: VPC CIDR/Name, 서브넷 3개의 Name·CIDR·AZ.

## 2-2. Security Group 2개

`VPC → Security groups → Create security group`

**① `wsc2026-keycloak-alb-sg`** (VPC = keycloak-vpc)

| 방향 | 타입 | 소스 |
|---|---|---|
| Inbound | HTTP 80 | `0.0.0.0/0` |
| Outbound | All | `0.0.0.0/0` |

**② `wsc2026-keycloak-sg`**

| 방향 | 타입 | 소스 |
|---|---|---|
| Inbound | Custom TCP **8080** | **`wsc2026-keycloak-alb-sg`** (SG 참조) |
| Outbound | All | `0.0.0.0/0` |

> ⚠️ **SSH(22) 인바운드를 절대 넣지 말 것.** 과제지가 "SSH 접근 불가"를 명시한다.
> 접속은 SSM Session Manager 로 한다.

## 2-3. EC2 (Keycloak) — 1.0점

### IAM 역할 먼저

`IAM → Roles → Create role → AWS service → EC2`
→ 정책 **`AmazonSSMManagedInstanceCore`** 연결 → 이름 **`wsc2026-keycloak-ec2-role`**

### 인스턴스 생성

`EC2 → Launch instances`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-keycloak` |
| AMI | **Amazon Linux 2023** |
| Instance type | **t3.medium** |
| Key pair | **Proceed without a key pair** |
| VPC / Subnet | `wsc2026-keycloak-vpc` / **`wsc2026-private-subnet-a`** |
| **Auto-assign public IP** | **Disable** |
| Security group | 기존 선택 → `wsc2026-keycloak-sg` |
| Advanced → IAM instance profile | `wsc2026-keycloak-ec2-role` |
| Advanced → User data | [`files/module2/user-data.sh`](files/module2/user-data.sh) 붙여넣기 |

3~5분 뒤 `EC2 → 인스턴스 선택 → Connect → Session Manager` 로 접속해 확인:

```bash
sudo docker ps
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/realms/master   # 200
```

> 📌 **채점(2-2)**: Name/타입/running, 서브넷 = `wsc2026-private-subnet-a`, SG = `wsc2026-keycloak-sg`.

## 2-4. ALB — 1.5점

### 대상 그룹

`EC2 → Target groups → Create target group`

| 항목 | 값 |
|---|---|
| Target type | **Instances** |
| Name | `wsc2026-keycloak-tg` |
| Protocol : Port | **HTTP : 8080** |
| VPC | `wsc2026-keycloak-vpc` |
| Health check path | **`/realms/master`** |

> 💡 Keycloak 25+ 는 `/health` 가 관리 포트(9000)로 옮겨졌다. 8080 에서 200 이 뜨는 `/realms/master` 를 쓴다.

다음 화면에서 `wsc2026-keycloak` 인스턴스를 **포트 8080** 으로 등록.

### 로드밸런서

`EC2 → Load Balancers → Create → Application Load Balancer`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-keycloak-alb` |
| Scheme | **Internet-facing** |
| VPC / Mappings | `wsc2026-keycloak-vpc` / **public-subnet-a, public-subnet-b** |
| Security group | `wsc2026-keycloak-alb-sg` |
| Listener | **HTTP : 80** → forward → `wsc2026-keycloak-tg` |

`Target groups → wsc2026-keycloak-tg → Targets` 상태가 **healthy** 가 될 때까지 대기.

> 📌 **채점(2-3)**: ALB Name/`internet-facing`, Listener 80, TargetHealth `healthy`, ALB SG.

## 2-5. Keycloak Realm / 그룹 / 사용자 — 1.5점

브라우저로 `http://<ALB-DNS>` 접속 → `admin` / `Skill53#!!@#`

### Realm

좌상단 드롭다운 → `Create realm` → Realm name **`wsc2026-aws`** → Create

### 그룹 (`Groups → Create group`)

- `dev-team`
- `infra-team`

### 사용자 (`Users → Add user`)

| Username | Join Groups | Password | Temporary |
|---|---|---|---|
| `dev-user` | `dev-team` | `Skills_dev53%$%` | **Off** |
| `infra-user` | `infra-team` | `Skills_infra53#@#` | **Off** |

각 사용자 → `Credentials 탭 → Set password` → **Temporary = Off** (필수. On 이면 로그인 시 비번 변경을 요구해 채점 실패)

> 📌 **채점(2-4)**: Realm 200 / 그룹 2개 / 사용자 2명 / 두 사용자 password grant 로그인 200.

## 2-6. SAML Client — 1.5점 (2-5, 2-6 과 맞물림)

### ⚠️ 순서 주의: 먼저 IAM Role ARN 이 필요하다

Keycloak 이 AWS 로 보내는 Role 속성값은 `<role-arn>,<provider-arn>` 형식이다.
그래서 **2-7 의 IAM 을 먼저 만들고 돌아오거나**, 최소한 계정 ID 를 알아둬야 한다.

`Clients → Create client`

| 항목 | 값 |
|---|---|
| Client type | **SAML** |
| **Client ID** | `urn:amazon:webservices` |
| Name | `amazon-aws` |

생성 후 `Settings` 탭:

| 항목 | 값 |
|---|---|
| **IDP-Initiated SSO URL name** | **`amazon-aws`** ← 채점 로그인 URL 이 이 값을 쓴다 |
| Valid redirect URIs | `https://signin.aws.amazon.com/saml` |
| Master SAML Processing URL | `https://signin.aws.amazon.com/saml` |
| Name ID format | `persistent` |
| Force POST binding | On |
| Sign documents | On |
| Client signature required | **Off** |

로그인 URL 은 이렇게 만들어진다:
```
http://<ALB-DNS>/realms/wsc2026-aws/protocol/saml/clients/amazon-aws
```

### Realm Role 2개 만들기 (Role 값 = ARN 쌍)

`Realm roles → Create role` — 이름을 **ARN 쌍 그대로** 넣는다.

```
arn:aws:iam::<ACCOUNT_ID>:role/wsc2026-dev-role,arn:aws:iam::<ACCOUNT_ID>:saml-provider/wsc2026-keycloak-idp
arn:aws:iam::<ACCOUNT_ID>:role/wsc2026-infra-role,arn:aws:iam::<ACCOUNT_ID>:saml-provider/wsc2026-keycloak-idp
```

`Groups → dev-team → Role mapping → Assign role` 로 dev ARN 롤을,
`infra-team` 에는 infra ARN 롤을 각각 할당.

### Client Scope 매퍼 3개

`Clients → urn:amazon:webservices → Client scopes → urn:amazon:webservices-dedicated → Add mapper → By configuration`

**① Role list** — "어떤 Role 을 부여할지"

| 항목 | 값 |
|---|---|
| Name | `aws-roles` |
| Role attribute name | `https://aws.amazon.com/SAML/Attributes/Role` |
| SAML Attribute NameFormat | **Basic** |
| Single Role Attribute | **On** |

**② User Property** — "세션을 어떤 이름으로 식별할지"

| 항목 | 값 |
|---|---|
| Name | `aws-session-name` |
| Property | `username` |
| SAML Attribute Name | `https://aws.amazon.com/SAML/Attributes/RoleSessionName` |
| SAML Attribute NameFormat | **Basic** |

**③ Hardcoded attribute** — "세션 유지 시간"

| 항목 | 값 |
|---|---|
| Name | `aws-session-duration` |
| Attribute name | `https://aws.amazon.com/SAML/Attributes/SessionDuration` |
| Attribute NameFormat | **Basic** |
| Attribute value | `3600` |

## 2-7. AWS IAM (SAML Provider + Role 2개) — 1.5점

### 메타데이터 내려받기

```bash
curl -s http://<ALB-DNS>/realms/wsc2026-aws/protocol/saml/descriptor -o metadata.xml
```
(또는 Keycloak `Realm settings → General → Endpoints → SAML 2.0 Identity Provider Metadata` 링크)

### SAML Provider

`IAM → Identity providers → Add provider`

| 항목 | 값 |
|---|---|
| Provider type | **SAML** |
| Provider name | `wsc2026-keycloak-idp` |
| Metadata document | `metadata.xml` 업로드 |

### 정책 2개

`IAM → Policies → Create policy → JSON`

| 이름 | 내용 |
|---|---|
| `wsc2026-dev-policy` | [`files/module2/wsc2026-dev-policy.json`](files/module2/wsc2026-dev-policy.json) — EC2/S3 읽기, `aws:RequestedRegion = ap-northeast-2` 조건 |
| `wsc2026-infra-policy` | [`files/module2/wsc2026-infra-policy.json`](files/module2/wsc2026-infra-policy.json) — EC2/S3/VPC/IAM 읽기 + Start/StopInstances, `protected=true` 태그는 Deny |

> 💡 VPC 조회 권한은 별도 서비스가 아니라 `ec2:Describe*` 에 포함된다.
> `Deny` 는 `Allow` 를 항상 이기므로 `protected` 태그 인스턴스의 시작/중지가 막힌다.

### 역할 2개

`IAM → Roles → Create role → SAML 2.0 federation`

| 항목 | 값 |
|---|---|
| SAML provider | `wsc2026-keycloak-idp` |
| | **Allow programmatic and AWS Management Console access** 선택 |

- 정책 `wsc2026-dev-policy` → 이름 **`wsc2026-dev-role`**
- 정책 `wsc2026-infra-policy` → 이름 **`wsc2026-infra-role`**

신뢰 정책은 [`files/module2/saml-trust-policy.json`](files/module2/saml-trust-policy.json) 형태가 되어야 한다
(`sts:AssumeRoleWithSAML` + `SAML:aud = https://signin.aws.amazon.com/saml`).

> 📌 **채점(2-5)**: SAML provider 이름, Role 2개, Policy 2개 존재.

## 2-8. SSO 수동 검증 — 2-6 채점 항목

채점관이 직접 확인한다. 미리 스스로 돌려봐야 한다.

먼저 `protected` 태그 인스턴스를 하나 만든다 (채점 스크립트가 만들어 준다):

```bash
aws ec2 run-instances --region ap-northeast-2 \
  --image-id $(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text --region ap-northeast-2) \
  --instance-type t3.micro \
  --subnet-id $(aws ec2 describe-subnets --filters Name=tag:Name,Values=wsc2026-private-subnet-a --query 'Subnets[0].SubnetId' --output text --region ap-northeast-2) \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=wsc2026-protected-ec2},{Key=protected,Value=true}]'
```

**시크릿 창**에서 `http://<ALB-DNS>/realms/wsc2026-aws/protocol/saml/clients/amazon-aws` 접속.

| 로그인 | 기대 결과 |
|---|---|
| `infra-user` | 우상단 계정이 `wsc2026-infra-role/infra-user` · 서울 **외** 리전에서도 EC2 조회 성공 · `wsc2026-protected-ec2` **중지 시도 → 오류** |
| `dev-user` | 계정이 `wsc2026-dev-role/dev-user` · 서울에서 EC2·S3 조회 성공 · **도쿄에서는 EC2·S3 조회 실패** |

---

# 3️⃣ Container Logging — 7.5점  `ap-northeast-1`

> **리전을 `도쿄(ap-northeast-1)` 로 변경. EKS 생성이 20분 걸리니 가장 먼저 시작할 것.**

```
log-generator (wsc2026-app)
      │ stdout JSON
      ▼
Fluent Bit (DaemonSet, 모든 노드)
      │ OTLP/HTTP :4318
      ▼
OTel Collector (Deployment)
      ├─ logs   → Loki  (Push API)
      └─ metrics→ count connector → Prometheus exporter :9464
                                          │ scrape
                                          ▼
                                     Prometheus
                                          │
                                       Grafana (LoadBalancer)
```

## 3-1. VPC

`VPC → Create VPC → **VPC and more**` (마법사가 서브넷·NAT·라우팅을 한번에 만들어 준다)

| 항목 | 값 |
|---|---|
| Name tag auto-generation | `wsc2026-logging` |
| IPv4 CIDR | `10.30.0.0/16` |
| AZs | 2 (`ap-northeast-1a`, `ap-northeast-1c`) |
| Public subnets | 2 |
| Private subnets | 2 |
| NAT gateways | **In 1 AZ** |
| DNS hostnames / resolution | ✔ ✔ |

만들어진 뒤 이름과 CIDR 을 과제지 값으로 **수정**한다.

| Name | CIDR | AZ |
|---|---|---|
| `wsc2026-logging-vpc` | `10.30.0.0/16` | — |
| public a | `10.30.1.0/24` | `ap-northeast-1a` |
| public c | `10.30.2.0/24` | `ap-northeast-1c` |
| private a | `10.30.10.0/24` | `ap-northeast-1a` |
| private c | `10.30.20.0/24` | `ap-northeast-1c` |

> 마법사가 기본 제안하는 CIDR 과 다르므로, **VPC and more 화면에서 "Customize subnet CIDR blocks" 를 열어 위 값으로 직접 지정**하는 편이 빠르다.

### ⭐ 서브넷 태그 — `type: LoadBalancer` 가 동작하려면 필수

| 대상 | 태그 |
|---|---|
| 퍼블릭 서브넷 2개 | `kubernetes.io/role/elb = 1` |
| 프라이빗 서브넷 2개 | `kubernetes.io/role/internal-elb = 1` |
| 서브넷 4개 전부 | `kubernetes.io/cluster/wsc2026-logging-cluster = shared` |

> 이 태그가 없으면 `log-generator` 와 `grafana` 의 LoadBalancer Service 가 **Pending 에서 멈춘다.** (3-1, 3-6 실패)

## 3-2. EKS 클러스터 + 노드 그룹

### 클러스터 역할

`IAM → Roles → Create role → AWS service → EKS → EKS - Cluster`
→ `AmazonEKSClusterPolicy` → 이름 `wsc2026-eks-cluster-role`

### 노드 역할

`IAM → Roles → Create role → AWS service → EC2`
→ 정책 3개: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`
→ 이름 `wsc2026-eks-node-role`

### 클러스터

`EKS → Add cluster → Create`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-logging-cluster` |
| Kubernetes version | **1.35** |
| Cluster IAM role | `wsc2026-eks-cluster-role` |
| Authentication mode | EKS API and ConfigMap |
| VPC | `wsc2026-logging-vpc` |
| Subnets | **4개 전부** |
| Cluster endpoint access | **Public and private** (또는 Public) |
| Add-ons | CoreDNS, kube-proxy, Amazon VPC CNI, **EBS CSI Driver** |

> 💡 **EBS CSI Driver 를 꼭 넣는다.** Loki/Prometheus/Grafana 의 PVC 가 바인딩되지 않으면 Pod 가 Pending 이다.
> Add-on 의 IAM 역할에는 `AmazonEBSCSIDriverPolicy` 가 필요하다.

생성에 **15~20분**. 그동안 모듈 1·4 를 진행한다.

### 노드 그룹

`클러스터 → Compute → Add node group`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-logging-nodegroup` |
| Node IAM role | `wsc2026-eks-node-role` |
| AMI type | **Amazon Linux 2023 (x86_64)** |
| Instance type | **t3.medium** |
| Desired / Min / Max | **2 / 2 / 2** |
| Subnets | **프라이빗 서브넷 2개만** |

### kubectl 연결 (CloudShell)

```bash
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-northeast-1
kubectl get nodes        # Ready 2개
```

## 3-3. 애플리케이션 배포 — 0.5점

```bash
kubectl create namespace wsc2026-app
kubectl apply -f deployment.yaml          # files/module3/deployment.yaml

kubectl get deploy -n wsc2026-app         # log-generator 1/1
LB=$(kubectl get svc log-generator -n wsc2026-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$LB/health"               # {"status": "ok"}
```

> ELB DNS 전파에 1~2분 걸린다. `curl` 이 실패하면 잠시 후 재시도.

> 📌 **채점(3-1)**: `log-generator 1/1` + `/health` 200.

## 3-4. Helm 리포지토리 등록

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace wsc2026-logging
```

## 3-5. 설치 순서 — Loki → OTel → Prometheus → Fluent Bit → Grafana

의존성 때문에 이 순서가 안전하다. values 파일은 전부 [`files/module3/`](files/module3) 에 있다.

### ① Loki — 1.0점

```bash
helm upgrade -i wsc2026-loki grafana/loki \
  -n wsc2026-logging -f loki-values.yaml
```
- `deploymentMode: SingleBinary` (단일 바이너리 모드)
- `allow_structured_metadata: true` ← OTLP 수신에 필수
- Service `wsc2026-loki:3100` 이 클러스터 내부에서 접근 가능해야 한다

### ② OpenTelemetry Collector — 1.0점

```bash
helm upgrade -i wsc2026-otel-collector open-telemetry/opentelemetry-collector \
  -n wsc2026-logging -f otel-collector-values.yaml
```

릴리스명이 `wsc2026-otel-collector` 여야 Deployment 이름이
`wsc2026-otel-collector-opentelemetry-collector` 가 된다 (채점 스크립트가 참조).

values 의 핵심 4가지:

| 설정 | 이유 |
|---|---|
| `image.repository: otel/opentelemetry-collector-contrib` | `count` connector, `transform` processor 는 contrib 에만 있음 |
| `processors.resource` | 로그에 `cluster` 리소스 속성 추가 |
| `transform/parse_json` | JSON 본문 파싱 → `level`/`message`/`service` 를 로그 속성으로 추출 |
| `connectors.count` | 레벨별 건수를 메트릭으로 변환 |

> ⚠️ **메트릭 이름 함정**: count connector 메트릭을 `log_record_count` 로 정의해야 한다.
> Prometheus exporter 가 monotonic sum 에 `_total` 접미사를 자동으로 붙여
> 최종적으로 `log_record_count_total` 로 노출된다.
> 여기서 이름을 `log_record_count_total` 로 두면 `log_record_count_total_total` 이 되어 3-5·3-7 이 전부 실패한다.

### ③ Prometheus — 1.0점

```bash
helm upgrade -i wsc2026-prometheus prometheus-community/prometheus \
  -n wsc2026-logging -f prometheus-values.yaml
```

릴리스명 `wsc2026-prometheus` → Deployment `wsc2026-prometheus-server`, 컨테이너 `prometheus-server`.
scrape target 은 OTel Collector 의 `:9464`.

### ④ Fluent Bit — 1.0점

```bash
helm upgrade -i wsc2026-fluent-bit fluent/fluent-bit \
  -n wsc2026-logging -f fluent-bit-values.yaml
```

| 요구사항 | values 반영 |
|---|---|
| 모든 노드에서 실행 | `kind: DaemonSet` |
| k8s 메타데이터 포함 | `[FILTER] kubernetes` |
| **자기 자신 로그 제외** | `Exclude_Path .../*_wsc2026-logging_*.log` |
| Loki 직접 전송 금지, OTel 로 전송 | `[OUTPUT] opentelemetry` → `:4318` |

### ⑤ Grafana — 1.5점 (3-6)

```bash
helm upgrade -i wsc2026-grafana grafana/grafana -n wsc2026-logging \
  -f grafana-values.yaml \
  --set-file dashboards.default.wsc2026-app-logs.json=dashboard-wsc2026-app-logs.json
```

- Service `type: LoadBalancer` (외부 접근)
- 데이터소스 이름은 **정확히 `Loki`, `Prometheus`** (채점이 이름으로 대조)
- admin / `Skill53@@`

## 3-6. 파이프라인 검증

```bash
N=wsc2026-logging
kubectl get pods -n $N

LB=$(kubectl get svc log-generator -n wsc2026-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$LB/burst?count=20&level=INFO" >/dev/null
curl -s "http://$LB/burst?count=10&level=WARN" >/dev/null
curl -s "http://$LB/burst?count=5&level=ERROR" >/dev/null
sleep 15

# OTel 이 로그를 받았는가
kubectl logs -n $N deploy/wsc2026-otel-collector-opentelemetry-collector --tail=50 | grep 'log records'

# Loki 라벨이 생겼는가
kubectl exec deploy/wsc2026-prometheus-server -n $N -c prometheus-server -- \
  wget -qO- "http://wsc2026-loki.$N.svc.cluster.local:3100/loki/api/v1/labels"

# Prometheus 에 메트릭이 있는가
kubectl exec deploy/wsc2026-prometheus-server -n $N -c prometheus-server -- \
  wget -qO- "http://localhost:9090/api/v1/query?query=log_record_count_total"
```

> 📌 **채점(3-2~3-5)**: FluentBit Pod 수 = 노드 수(2), OTel `log records ≥ 1`,
> Loki Pod ≥ 1 & Labels ≥ 1, Prometheus Pod ≥ 1 & Metrics ≥ 1(레벨 3종이면 3).

## 3-7. Grafana 대시보드 — 1.5점 (수동 채점)

```bash
kubectl get svc wsc2026-grafana -n wsc2026-logging   # EXTERNAL-IP 확인
```
브라우저 접속 → `admin` / `Skill53@@` → 대시보드 **`wsc2026-app-logs`**

[`files/module3/dashboard-wsc2026-app-logs.json`](files/module3/dashboard-wsc2026-app-logs.json) 이 아래를 모두 담고 있다.

**Overview 섹션**
- Stat 4개 — INFO Logs / Warn Logs / Error Logs / Total Logs
- Timeseries — 레벨별 발생 추이 (INFO=초록, WARN=노랑, ERROR=빨강)
- Timeseries — Error Rate(%) / Warn Rate(%) 추이
- Pie Chart — 레벨별 분포
- Gauge 2개 — Error Rate(%), Warn Rate(%)

**Logs by Level 섹션**
- Bar Chart — 레벨별 로그 카운트
- Logs 패널 — `{namespace="$namespace"}`

**Template Variable**: `namespace` (Loki 라벨 기반)

> 📌 **채점(3-7)**: 위 `burst` 요청 직후 **INFO=20, WARN=10, ERROR=5** 가 정확히 일치해야 한다.
> 채점 전에 다른 부하를 주지 말고, 카운터가 누적이므로 **필요하면 OTel Collector Pod 를 재시작해 0 부터 다시** 센다.

---

# 4️⃣ Workflow — 7.5점  `ap-southeast-1`

> **리전을 `싱가포르(ap-southeast-1)` 로 변경.**

```
S3 (incoming/sample-orders.json)
      │ FetchOrders (SDK 직접 통합)
      ▼
ValidateOrders  (Map, 동시 5) → wsc2026-order-validator
      ▼
ProcessAndStore (Map, 동시 10)
      ├ Choice valid?
      │   ├ true  → payment-processor → PutItem(orders) → UpdateItem(inventory)
      │   └ false → Pass (건너뜀)
      ▼
RecordResult → PutItem(wsc2026-pipeline-history)
```

## 4-1. S3 — 0.5점

`S3 → Create bucket`

| 항목 | 값 |
|---|---|
| Name | `wsc2026-order-pipeline` |
| Region | ap-southeast-1 |
| Versioning | **Enable** |

`Create folder → incoming/` → [`files/module4/sample-orders.json`](files/module4/sample-orders.json) 업로드.

## 4-2. DynamoDB 3개 — 1.0점

`DynamoDB → Create table` (셋 다 **Capacity mode = On-demand**)

| 테이블 | Partition key | Sort key |
|---|---|---|
| `wsc2026-orders` | `order_id` (String) | `ordered_at` (String) |
| `wsc2026-inventory` | `product_id` (String) | — |
| `wsc2026-pipeline-history` | `execution_id` (String) | `started_at` (String) |

### TTL 활성화

`wsc2026-pipeline-history → Additional settings → Time to Live → Turn on`
→ TTL attribute name **`expires_at`**

### Inventory 시드 적재

CloudShell:

```bash
aws dynamodb put-item --region ap-southeast-1 --table-name wsc2026-inventory \
  --item '{"product_id":{"S":"PROD-A100"},"product_name":{"S":"Wireless Keyboard"},"stock":{"N":"50"},"category":{"S":"electronics"}}'
aws dynamodb put-item --region ap-southeast-1 --table-name wsc2026-inventory \
  --item '{"product_id":{"S":"PROD-B200"},"product_name":{"S":"USB-C Monitor"},"stock":{"N":"20"},"category":{"S":"electronics"}}'
aws dynamodb put-item --region ap-southeast-1 --table-name wsc2026-inventory \
  --item '{"product_id":{"S":"PROD-C300"},"product_name":{"S":"Bluetooth Speaker"},"stock":{"N":"100"},"category":{"S":"audio"}}'
```

> 📌 **채점(4-2)**: 3개 테이블의 키 스키마 + history TTL `ENABLED`.

## 4-3. Lambda 2개 — 1.5점

`Lambda → Create function` × 2 (**Runtime: Python 3.13**)

| 함수 | 코드 |
|---|---|
| `wsc2026-order-validator` | [`files/module4/wsc2026-order-validator.py`](files/module4/wsc2026-order-validator.py) |
| `wsc2026-payment-processor` | [`files/module4/wsc2026-payment-processor.py`](files/module4/wsc2026-payment-processor.py) |

코드를 붙여넣고 **Deploy** 를 반드시 누른다. 실행 역할은 기본 생성(`AWSLambdaBasicExecutionRole`)으로 충분하다.

> 💡 `validator` 는 `expires_at`(현재+30일 epoch)도 함께 반환한다.
> ASL 에는 현재 시각을 epoch 으로 얻는 내장 함수가 없어서, History 테이블 TTL 값을 여기서 만들어 넘긴다.
> 반환 형태에 `valid` / `order` / `errors` 가 그대로 있으므로 채점(4-4)에는 영향이 없다.

## 4-4. Lambda 동작 확인 — 1.5점

```bash
aws lambda invoke --region ap-southeast-1 --function-name wsc2026-order-validator \
  --cli-binary-format raw-in-base64-out \
  --payload '{"order_id":"ORD-T1","product_id":"P1","quantity":2,"unit_price":1000,"payment_method":"CARD"}' /tmp/v
cat /tmp/v      # "valid": true,  "errors": []

aws lambda invoke --region ap-southeast-1 --function-name wsc2026-order-validator \
  --cli-binary-format raw-in-base64-out \
  --payload '{"order_id":"BAD","product_id":"","quantity":0,"unit_price":-1,"payment_method":"X"}' /tmp/i
cat /tmp/i      # "valid": false, errors 5개
```

> 📌 **채점(4-4)**: `VALID true ERRORS=0` / `INVALID false ERRORS=5`.
> 실패 케이스는 **5개 검증 규칙이 모두 걸리도록** 되어 있다. 규칙을 하나라도 합치면 개수가 안 맞는다.

## 4-5. Step Functions — 1.5점

### 실행 역할

`IAM → Roles → Create role → AWS service → Step Functions` → 이름 `wsc2026-sfn-role`
→ 인라인 정책으로 아래 권한 부여:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::wsc2026-order-pipeline/*" },
    { "Effect": "Allow", "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:ap-southeast-1:<ACCOUNT_ID>:function:wsc2026-order-validator",
        "arn:aws:lambda:ap-southeast-1:<ACCOUNT_ID>:function:wsc2026-payment-processor"
      ] },
    { "Effect": "Allow", "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem"],
      "Resource": [
        "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/wsc2026-orders",
        "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/wsc2026-inventory",
        "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/wsc2026-pipeline-history"
      ] }
  ]
}
```

### 상태 머신

`Step Functions → Create state machine → Create from blank → Code 탭`
→ [`files/module4/wsc2026-order-pipeline.asl.json`](files/module4/wsc2026-order-pipeline.asl.json) 전체 붙여넣기

| 항목 | 값 |
|---|---|
| Name | `wsc2026-order-pipeline` |
| Type | **Standard** |
| Execution role | `wsc2026-sfn-role` |

ASL 설계 포인트:

| 상태 | 핵심 |
|---|---|
| `FetchOrders` | `aws-sdk:s3:getObject` + `ResultSelector: States.StringToJson($.Body)` → `ResultPath: $.orderData` |
| `ValidateOrders` | Map, `MaxConcurrency: 5`, Lambda 재시도 2회(Interval 2, Backoff 2.0), `ResultPath: $.validationResults` |
| `ProcessAndStore` | Map, `MaxConcurrency: 10`, 내부 Choice → 유효 시에만 결제→PutItem→UpdateItem 순차 실행 |
| | DynamoDB 실패 재시도 3회(Interval 1, Backoff 2.0), 그 외 에러는 Catch → `SkipOnError` Pass |
| `RecordResult` | `$$.Execution.Id` / `$$.Execution.StartTime` 사용, status `COMPLETED` |
| `PipelineFailed` | FetchOrders·ValidateOrders 의 복구 불가 에러에서 전이, status `FAILED` + error/cause |

> ⚠️ **`processed_orders` 는 5 다.** 채점 기대값이 `COMPLETED 5 5` 이므로,
> `processed_orders` 는 "결제 성공 건수"가 아니라 **ProcessAndStore Map 의 전체 반복 수(=5)** 로 기록한다.
> 유효 주문 수(2)는 `valid_orders` 에 따로 담는다.

## 4-6. E2E 실행 — 1.5점

```bash
S=$(aws stepfunctions list-state-machines --region ap-southeast-1 \
     --query "stateMachines[?name=='wsc2026-order-pipeline'].stateMachineArn|[0]" --output text)

E=$(aws stepfunctions start-execution --region ap-southeast-1 --state-machine-arn $S \
     --input '{"bucket":"wsc2026-order-pipeline","key":"incoming/sample-orders.json"}' \
     --query executionArn --output text)
sleep 30

aws stepfunctions describe-execution --region ap-southeast-1 --execution-arn $E --query status --output text
aws dynamodb scan --region ap-southeast-1 --table-name wsc2026-orders --query Count --output text
```

기대 결과:

| 확인 | 값 |
|---|---|
| 실행 status | `SUCCEEDED` |
| `wsc2026-orders` Count | **2** (유효 주문 2건) |
| `PROD-A100` stock | **48** (50 − 2) |
| `PROD-B200` stock | **19** (20 − 1) |
| `PROD-C300` stock | **100** (변화 없음) |
| history 마지막 항목 | `COMPLETED  5  5` |

`sample-orders.json` 5건 중 유효한 것은 2건뿐이다:

| order_id | 판정 | 이유 |
|---|---|---|
| `ORD-20260521-001` | ✅ | — |
| `ORD-20260521-002` | ✅ | — |
| `ORD-20260521-003` | ❌ | `quantity: 0` |
| `INVALID-004` | ❌ | `ORD-` 접두사 아님 + `payment_method: CRYPTO` |
| `ORD-20260521-005` | ❌ | `product_id` 빈 문자열 |

> ⚠️ **재실행 시 재고가 계속 깎인다.** 채점 전에 반드시 inventory 를 50/20/100 으로 되돌리고,
> `wsc2026-orders` 를 비운 뒤 한 번만 실행한다.

---

# ✅ 마무리 체크리스트

경기 종료 전 CloudShell 에서 모듈별 `mark.sh` 를 한 번씩 돌린다.

```bash
bash mark2_cdn.sh
bash mark2_keycloak.sh
bash mark2_logging.sh
bash mark2_workflow.sh
```

**자주 터지는 곳**

| 증상 | 원인 |
|---|---|
| 1-2 이후 전부 실패 | CloudFront 배포에 `Name = wsc2026-cdn` **태그** 누락 |
| 1-5 Lambda 배포 거부 | 신뢰 정책에 `edgelambda.amazonaws.com` 없음 / 타임아웃 > 30초 / 환경변수 사용 |
| 1-5 정책 미출력 | 인라인 정책으로 붙임 → **관리형 정책 attach** 로 변경 |
| 2-4 로그인 실패 | 사용자 비밀번호 **Temporary = On** |
| 2-6 URL 404 | SAML Client 의 **IDP-Initiated SSO URL name ≠ `amazon-aws`** |
| 3-1 / 3-6 LB Pending | 퍼블릭 서브넷 `kubernetes.io/role/elb=1` 태그 누락 |
| 3-x Pod Pending | EBS CSI Driver 애드온 미설치 → PVC 바인딩 실패 |
| 3-5 Metrics 0 | count connector 메트릭 이름을 `log_record_count_total` 로 지정 (→ `_total_total`) |
| 3-7 카운트 불일치 | 이전 부하가 누적됨 → OTel Collector Pod 재시작 후 다시 burst |
| 4-6 재고 불일치 | 파이프라인을 두 번 이상 실행 |

**마지막으로**
- 실행 중인 부하 테스트·`burst` 루프 전부 중지 (유의사항 7번)
- 모든 리소스 이름/태그의 **대소문자** 재확인 (유의사항 9번)
