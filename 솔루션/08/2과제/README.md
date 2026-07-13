# 2과제 콘솔(GUI) 솔루션 — 처음부터 끝까지

AWS **Management Console**만으로 4개 모듈을 만드는 방법입니다. (테라폼 없이 손으로 클릭)

- `<비번호>` 는 본인 비번호로 바꿉니다. (예: `101`)
- **리전을 반드시 확인**하세요. 모듈마다 리전이 다릅니다. 콘솔 우측 상단 리전 선택 메뉴로 바꿉니다.
- **이름·태그·값은 대소문자까지 정확히** 입력하세요. (채점이 정확히 매칭)

| 모듈 | 리전 | 만드는 것 |
|------|------|-----------|
| 1 NoSQL | **ap-northeast-2** (서울) | DynamoDB 테이블 + GSI + 데이터 20건 + result.json |
| 2 CDN | **us-east-1** (버지니아 북부) | S3 + OAC + CloudFront + CloudFront Function |
| 3 Workflow | **ap-southeast-1** (싱가포르) | S3 + DynamoDB + Lambda + Step Functions |
| 4 RDS | **ap-northeast-3** (오사카) | Aurora Serverless v2 + Data API + Secret + Lambda |

> 📌 제공 파일(`index.html`, `style.css`, `image.png`, `data.csv`, `lambda_function.py`, `cdn-add-security-header.js`, `insert.sh`, `query.sh`)은 배포파일 폴더에 있습니다. 콘솔 작업 시 업로드/붙여넣기로 사용합니다.

---

# 사전 준비

## 계정 ID(ACCOUNT_ID) 확인

정책·ARN 작성에 계정 ID(12자리)가 필요합니다.

- 콘솔 우측 상단 계정 메뉴에 표시되거나,
- CloudShell에서:

  ```bash
  aws sts get-caller-identity --query Account --output text
  ```

문서 안 `<ACCOUNT_ID>`, `<비번호>`, `<...ARN>` 은 전부 본인 값으로 바꿉니다.

## 제공 파일을 CloudShell에 올리기

`insert.sh`, `query.sh`, 그리고 채점 스크립트 `grade_module*_v2.sh` 는 CloudShell에서 실행합니다.

1. 콘솔 우측 상단 **CloudShell**(`>_`) 실행.
2. **Actions → Upload file** 로 필요한 파일을 업로드.
3. CloudShell은 리전 개념이 없고, 명령의 `--region` 값으로 대상 리전을 지정합니다. (스크립트에 이미 포함)

## 작업 순서 팁

- **Module 4 (Aurora)를 가장 먼저** 시작하세요. 기동에 ~10분 걸리므로, 만들어 두고 1→2→3을 진행하면 시간을 아낍니다.
- CloudFront 배포도 ~3분 걸리니 Module 2 배포 생성 후 다른 작업을 병행하세요.

---

# Module 1. NoSQL (DynamoDB) — 리전: ap-northeast-2

## 1-1. DynamoDB 테이블 생성

1. 콘솔 리전을 **서울(ap-northeast-2)** 로 변경.
2. **DynamoDB** 서비스 → 왼쪽 **테이블** → **테이블 생성**.
3. 입력:

   | 항목 | 값 |
   |------|-----|
   | 테이블 이름 | `nosql-products` |
   | 파티션 키 | `product_id` / **문자열(String)** |
   | 정렬 키 | `category` / **문자열(String)** |
   | 테이블 설정 | **설정 사용자 지정** |
   | 용량 모드 | **온디맨드(On-demand)** |

4. **테이블 생성** 클릭.

## 1-2. GSI(글로벌 보조 인덱스) 생성

1. 만든 `nosql-products` 테이블 클릭 → **인덱스** 탭 → **인덱스 생성**.
2. 입력:

   | 항목 | 값 |
   |------|-----|
   | 파티션 키 | `category` / **문자열(String)** |
   | 정렬 키 | `price` / **숫자(Number)** |
   | 인덱스 이름 | `category-price-index` |
   | 속성 프로젝션 | **모두(All)** |

3. **인덱스 생성** 클릭. (Active 될 때까지 잠시 대기)

## 1-3. 스트림 활성화

1. `nosql-products` 테이블 → **내보내기 및 스트림**(Exports and streams) 탭.
2. **DynamoDB 스트림** → **켜기(Turn on)**.
3. 보기 유형: **새 이미지와 이전 이미지(New and old images)** 선택 → **스트림 켜기**.

## 1-4. 데이터 20건 저장 (CloudShell에서 `insert.sh`)

> 콘솔에서 20건을 손으로 넣는 건 비효율적이라 제공된 `insert.sh`를 씁니다.

1. 콘솔 우측 상단 **CloudShell**(`>_`) 아이콘 클릭.
2. 제공된 `insert.sh`를 CloudShell 우측 상단 **Actions → Upload file** 로 올립니다.
3. 실행:

   ```bash
   bash insert.sh
   # 출력: success 20 / fail 0
   ```

4. 콘솔 DynamoDB → 테이블 → **항목 탐색(Explore items)** 에서 20건 확인.

## 1-5. 조회 결과 저장 (`query.sh` → ~/result.json)

1. 같은 CloudShell에 제공된 `query.sh` 업로드.
2. 실행:

   ```bash
   bash query.sh electronics
   cat ~/result.json
   ```

3. `~/result.json` 에 아래 형태로 저장되면 완료:

   ```json
   [
     { "product_id": "P001", "category": "Electronics", "price": 100, ... }
   ]
   ```

✅ **Module 1 끝.**

---

# Module 2. CDN (S3 + OAC + CloudFront) — 리전: us-east-1

> ⚠️ CloudFront 배포에 최대 3분 걸립니다.

## 2-1. S3 버킷 생성 + 파일 업로드

1. 콘솔 리전을 **버지니아 북부(us-east-1)** 로 변경.
2. **S3** → **버킷 만들기**.

   | 항목 | 값 |
   |------|-----|
   | 버킷 이름 | `cdn-static-<비번호>` |
   | 리전 | us-east-1 |
   | 퍼블릭 액세스 차단 | **모두 차단(기본값 유지)** |

3. **버킷 만들기**.
4. 버킷 열기 → **업로드** → 제공된 **`index.html`, `style.css`, `image.png`** 3개 추가 → **업로드**.

## 2-2. CloudFront Function 생성 (응답 헤더 추가)

1. **CloudFront** 콘솔 (글로벌 서비스) → 왼쪽 **함수(Functions)** → **함수 생성**.
2. 이름: `cdn-add-security-header` → **함수 생성**.
3. **런타임**: `cloudfront-js-2.0` 선택.
4. **개발(Development)** 탭 코드 칸에 아래 붙여넣기:

   ```javascript
   function handler(event) {
     var response = event.response;
     response.headers['x-custom-header'] = { value: 'wsc2026' };
     return response;
   }
   ```

5. **변경 사항 저장** → **게시(Publish)** 탭 → **함수 게시**.

## 2-3. OAC(Origin Access Control) 생성

1. CloudFront → 왼쪽 **원본 액세스(Origin access)** → **컨트롤 설정 생성**.
2. 입력:

   | 항목 | 값 |
   |------|-----|
   | 이름 | `cdn-oac` |
   | 서명 동작 | **서명 요청(권장)** |
   | 원본 유형 | **S3** |

3. **생성**.

## 2-4. CloudFront 배포(Distribution) 생성

1. CloudFront → **배포** → **배포 생성**.
2. **원본(Origin)**:

   | 항목 | 값 |
   |------|-----|
   | 원본 도메인 | 드롭다운에서 **S3 버킷 `cdn-static-<비번호>` 선택** → `cdn-static-<비번호>.s3.us-east-1.amazonaws.com` |
   | 원본 액세스 | **Origin access control settings (recommended)** 선택 → `cdn-oac` |

   > ⚠️ 원본 도메인은 반드시 **S3 REST 엔드포인트**(`...s3.us-east-1.amazonaws.com`)여야 합니다. "웹사이트 엔드포인트"(`...s3-website...`)를 고르면 OAC가 동작하지 않습니다. 드롭다운에서 버킷을 선택하면 REST 엔드포인트가 자동 입력됩니다.

3. **기본 캐시 동작(Default cache behavior)**:

   | 항목 | 값 |
   |------|-----|
   | 뷰어 프로토콜 정책 | **Redirect HTTP to HTTPS** |
   | 허용된 HTTP 방법 | GET, HEAD |
   | 함수 연결 → **뷰어 응답(Viewer response)** | **CloudFront Function** → `cdn-add-security-header` |

4. **설정(Settings)**:

   | 항목 | 값 |
   |------|-----|
   | 기본값 루트 객체 | `index.html` |
   | 설명(Description/Comment) | `cdn-<비번호>` ← **채점 식별용, 정확히** |

5. **배포 생성**.
6. 상단에 뜨는 **"정책을 S3 버킷에 복사" 배너 → 정책 복사** 클릭.
7. **태그** 추가: 배포 → **태그** 탭 → `Module = CDN`.

## 2-5. S3 버킷 정책 적용 (CloudFront만 접근 허용)

1. **S3** → `cdn-static-<비번호>` → **권한** 탭 → **버킷 정책** → **편집**.
2. 2-4에서 복사한 정책을 붙여넣기 (없으면 아래, `<ACCOUNT_ID>`·`<DIST_ID>` 교체):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "AllowCloudFrontServicePrincipalReadOnly",
       "Effect": "Allow",
       "Principal": { "Service": "cloudfront.amazonaws.com" },
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::cdn-static-<비번호>/*",
       "Condition": {
         "StringEquals": {
           "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DIST_ID>"
         }
       }
     }]
   }
   ```

3. **저장**.

## 2-6. 동작 확인 (배포 완료 후 ~3분)

CloudShell에서:

```bash
CF=<배포 도메인 이름>   # 예) d111111abcdef8.cloudfront.net
curl -sI "https://$CF/index.html?v=1" | grep -i X-Custom-Header
# 결과: X-Custom-Header: wsc2026
```

S3 직접 접근이 막혔는지도 확인 (403/400 이면 정상):

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://cdn-static-<비번호>.s3.us-east-1.amazonaws.com/index.html"
```

✅ **Module 2 끝.**

---

# Module 3. Workflow (S3 + Lambda + DynamoDB + Step Functions) — 리전: ap-southeast-1

## 3-1. S3 버킷 생성 + data.csv 업로드

1. 콘솔 리전을 **싱가포르(ap-southeast-1)** 로 변경.
2. **S3** → **버킷 만들기** → 이름 `workflow-input-<비번호>` → 생성.
3. 버킷 → **속성** 탭 → **태그** → `Module = Workflow` 추가.
4. **업로드** → 제공된 **`data.csv`** 업로드.

## 3-2. DynamoDB 출력 테이블 생성

1. **DynamoDB** (싱가포르 리전) → **테이블 생성**.

   | 항목 | 값 |
   |------|-----|
   | 테이블 이름 | `workflow-output` |
   | 파티션 키 | `id` / **문자열(String)** |
   | 용량 모드 | **온디맨드** |

2. **테이블 생성**.

## 3-3. Lambda 함수 생성 (workflow-transform)

1. **Lambda** (싱가포르 리전) → **함수 생성** → **새로 작성**.

   | 항목 | 값 |
   |------|-----|
   | 함수 이름 | `workflow-transform` |
   | 런타임 | **Python 3.12** |
   | 아키텍처 | x86_64 |

2. **함수 생성**.
3. **코드** 탭 → `lambda_function.py` 내용을 제공된 파일로 교체 → **Deploy**.
4. **구성(Configuration)** → **일반 구성** → **편집** → **제한 시간(Timeout) 60초** → 저장.
5. **구성** → **환경 변수** → **편집** → 추가:

   | 키 | 값 |
   |----|-----|
   | `TABLE_NAME` | `workflow-output` |

6. **구성** → **권한** → 실행 역할 이름 클릭(IAM 콘솔 열림) → **권한 추가** → **인라인 정책 생성** → JSON:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject"],
         "Resource": "arn:aws:s3:::workflow-input-<비번호>/*"
       },
       {
         "Effect": "Allow",
         "Action": ["dynamodb:PutItem", "dynamodb:BatchWriteItem", "dynamodb:DescribeTable"],
         "Resource": "arn:aws:dynamodb:ap-southeast-1:<ACCOUNT_ID>:table/workflow-output"
       }
     ]
   }
   ```

   → 정책 이름 `workflow-transform-policy` → 생성.

## 3-4. Step Functions 상태 머신 생성 (workflow-state-machine)

1. **Step Functions** (싱가포르 리전) → **상태 머신 생성** → **처음부터 작성(Blank)**.
2. 우측 상단 코드 편집기(**{} Code**)에 아래 정의 붙여넣기 (`<ACCOUNT_ID>` 교체):

   ```json
   {
     "Comment": "WSC 2026 workflow pipeline",
     "StartAt": "ValidateInput",
     "States": {
       "ValidateInput": { "Type": "Pass", "Next": "TransformAndSave" },
       "TransformAndSave": {
         "Type": "Task",
         "Resource": "arn:aws:states:::lambda:invoke",
         "Parameters": {
           "FunctionName": "arn:aws:lambda:ap-southeast-1:<ACCOUNT_ID>:function:workflow-transform",
           "Payload.$": "$"
         },
         "Next": "Success"
       },
       "Success": { "Type": "Succeed" }
     }
   }
   ```

3. 우측 상단 **다음/설정** →

   | 항목 | 값 |
   |------|-----|
   | 이름 | `workflow-state-machine` |
   | 유형 | **표준(Standard)** |
   | 권한 | **새 역할 생성** (또는 기존 역할) |

4. **상태 머신 생성**.
5. 실행 역할 권한을 **`lambda:InvokeFunction` 만** 갖도록 정리 (IAM에서 역할 확인 — 자동 생성 정책이 넓으면 아래로 교체):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "lambda:InvokeFunction",
       "Resource": "arn:aws:lambda:ap-southeast-1:<ACCOUNT_ID>:function:workflow-transform"
     }]
   }
   ```

## 3-5. 실행 → 데이터 저장 확인

1. `workflow-state-machine` → **실행 시작(Start execution)**.
2. 입력에 붙여넣기:

   ```json
   { "bucket": "workflow-input-<비번호>", "key": "data.csv" }
   ```

3. **실행 시작** → 상태가 **Succeeded** 인지 확인.
4. **DynamoDB** → `workflow-output` → **항목 탐색** 에서 10건 저장 확인.
   또는 CloudShell:

   ```bash
   aws dynamodb scan --table-name workflow-output --region ap-southeast-1 --select COUNT
   # Count >= 1 이면 정상
   ```

✅ **Module 3 끝.**

---

# Module 4. RDS Connection (Aurora Serverless v2 + Data API + Lambda) — 리전: ap-northeast-3

> ⚠️ Aurora 기동에 ~10분 걸립니다. 가장 먼저 만들어 두면 시간 절약.

## 4-1. Aurora MySQL Serverless v2 클러스터 생성

1. 콘솔 리전을 **오사카(ap-northeast-3)** 로 변경.
2. **RDS** → **데이터베이스 생성** → **표준 생성**.

   | 항목 | 값 |
   |------|-----|
   | 엔진 유형 | **Aurora (MySQL Compatible)** |
   | 버전 | **Aurora MySQL 3.07 이상** (예: 3.08.x) |
   | 템플릿 | 개발/테스트 (또는 프로덕션) |
   | DB 클러스터 식별자 | `rds-aurora-cluster` |
   | 마스터 사용자 이름 | `admin` |
   | 자격 증명 관리 | **AWS Secrets Manager에서 관리** ✅ |
   | 인스턴스 구성 | **서버리스 v2** |
   | 용량(ACU) | 최소 **0.5** / 최대 **4** |
   | 초기 데이터베이스 이름(추가 구성) | `appdb` |
   | 퍼블릭 액세스 | 아니요 |

3. **RDS Data API** 활성화: 추가 구성에서 **RDS Data API 사용(Enable the RDS Data API)** 체크.
4. **데이터베이스 생성**. (기동 ~10분)
5. 태그: 클러스터 → **태그** → `Module = RDSConnection`.

> 💡 자격 증명을 Secrets Manager로 관리하면 시크릿이 자동 생성됩니다. 이름이 `rds/aurora/admin`이 아니면, 아래처럼 별도 시크릿을 만들거나 이름을 맞춰야 채점을 통과합니다.

## 4-2. Secret 이름 맞추기 (rds/aurora/admin)

자동 생성 시크릿 이름이 다르면, **Secrets Manager** → **새 시크릿 저장** →
- 유형: **Amazon RDS 데이터베이스 자격 증명**
- 사용자/암호: 위 admin 자격 증명
- DB: `rds-aurora-cluster`
- 시크릿 이름: **`rds/aurora/admin`**

> Data API + Lambda가 참조할 **시크릿 ARN**을 메모해 둡니다.

## 4-3. Lambda 함수 생성 (rds-query-function)

1. **Lambda** (오사카 리전) → **함수 생성** → **새로 작성**.

   | 항목 | 값 |
   |------|-----|
   | 함수 이름 | `rds-query-function` |
   | 런타임 | **Python 3.12** |
   | VPC | **설정 안 함** (Data API는 퍼블릭 HTTPS) |

2. **코드** 탭 → 제공된 `lambda_function.py`(rds용) 붙여넣기 → **Deploy**.
3. **구성** → **일반 구성** → Timeout **60초**.
4. **구성** → **환경 변수** 추가:

   | 키 | 값 |
   |----|-----|
   | `CLUSTER_ARN` | Aurora **클러스터 ARN** |
   | `SECRET_ARN` | `rds/aurora/admin` **시크릿 ARN** |
   | `DB_NAME` | `appdb` |

   > 클러스터 ARN: RDS → `rds-aurora-cluster` → **구성** 탭에서 확인.

5. **구성** → **권한** → 실행 역할 → **인라인 정책 생성** → JSON (`<ACCOUNT_ID>`, 시크릿 ARN 교체):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "rds-data:ExecuteStatement",
         "Resource": "arn:aws:rds:ap-northeast-3:<ACCOUNT_ID>:cluster:rds-aurora-cluster"
       },
       {
         "Effect": "Allow",
         "Action": "secretsmanager:GetSecretValue",
         "Resource": "<rds/aurora/admin 시크릿 ARN>"
       }
     ]
   }
   ```

   → 이름 `rds-query-function-policy` → 생성.

## 4-4. 실행 확인

1. Lambda → `rds-query-function` → **테스트** 탭 → 빈 이벤트 `{}` 로 **테스트**.
   또는 CloudShell:

   ```bash
   aws lambda invoke \
     --function-name rds-query-function \
     --region ap-northeast-3 \
     response.json
   cat response.json
   ```

2. `statusCode: 200` 과 products 조회 결과(JSON)가 나오면 정상.

> Aurora가 아직 **Available** 아니면 실패합니다. 상태 확인 후 재실행.

✅ **Module 4 끝.**

---

# 최종 채점 (CloudShell)

채점은 **CloudShell**에서 진행합니다. 각 모듈 리전을 확인하고 스크립트를 실행하세요.

```bash
bash grade_module1_v2.sh
bash grade_module2_v2.sh
bash grade_module3_v2.sh
bash grade_module4_v2.sh
```

## 빠른 자체 점검 체크리스트

| # | 확인 | 명령/방법 |
|---|------|-----------|
| 1-1 | 테이블 존재 | DynamoDB(서울) `nosql-products` |
| 1-2 | PK/SK | product_id(HASH), category(RANGE) |
| 1-3 | GSI | `category-price-index` |
| 1-4 | 20건 | scan COUNT >= 20 |
| 1-5 | result.json | `cat ~/result.json` |
| 2-1 | 버킷 | `cdn-static-<비번호>` (us-east-1) |
| 2-2 | 파일 3개 | index.html/style.css/image.png |
| 2-3 | 배포 | Comment `cdn-<비번호>`, Enabled |
| 2-4 | OAC + 직접차단 | S3 직접 URL 403/400 |
| 2-5 | 헤더 | `X-Custom-Header: wsc2026` |
| 3-1 | 버킷 | `workflow-input-<비번호>` (싱가포르) |
| 3-2 | 테이블 | `workflow-output` |
| 3-3 | Lambda | `workflow-transform` py3.12/60s/TABLE_NAME |
| 3-4 | SFN | `workflow-state-machine` STANDARD |
| 3-5 | 데이터 | scan COUNT >= 1 |
| 4-1 | 클러스터 | `rds-aurora-cluster` MySQL 3.07+ |
| 4-2 | Data API | HttpEndpointEnabled = true |
| 4-3 | Secret | `rds/aurora/admin` |
| 4-4 | Lambda | `rds-query-function` |
| 4-5 | 실행 | response.json 정상 JSON |

---

# 정리 (채점 후)

만든 순서 역순으로 콘솔에서 삭제하거나, 리소스별로:

- **Module 4**: RDS 클러스터/인스턴스 삭제 → Secret 삭제 → Lambda 삭제
- **Module 3**: SFN 삭제 → Lambda 삭제 → DynamoDB `workflow-output` 삭제 → S3 비우고 삭제
- **Module 2**: CloudFront 배포 **비활성화 후 삭제** → Function 삭제 → OAC 삭제 → S3 비우고 삭제
- **Module 1**: DynamoDB `nosql-products` 삭제

> S3는 **버킷 비우기(Empty)** 후 삭제해야 합니다. CloudFront는 **Disable → 배포 완료 대기 → Delete** 순서입니다.
