# 모듈 4 — REST API Implement (콘솔 가이드)

**리전: ap-southeast-1 (싱가포르)** — 우측 상단에서 반드시 변경

> 목표: **API Gateway(REST) → Lambda → DynamoDB** 로 학생 정보 create/read.
> Lambda는 Table 이름을 담은 **env 파일을 Layer**로 참조. HTTP 메서드별 처리 + 검증(400/404/405).

## 목표 리소스 이름
| 항목 | 값 |
|------|-----|
| Lambda | `wsc2026-worldschool-management` (Python) |
| Layer | `wsc2026-worldschool-env-layer` (env 파일) |
| DynamoDB | `wsc2026-worldschool-table` (PK `admission_year` N, SK `student_name` S, **삭제 방지 ON**) |
| API Gateway | `wsc2026-worldschool-api` (REST), 스테이지 `wsc2026-worldschool-api-stage`, 리소스 **ANY** |

## API 동작 규약
| 메서드 | 입력 | 응답 |
|--------|------|------|
| GET (쿼리 없음) | - | 전체 목록 200 |
| GET `admission_year=2026&student_name=홍길동` | 쿼리스트링 | `{admission_year, student_name}` 200 / 없으면 404 "찾을 수 없습니다." |
| POST `{admission_year:2026, student_name:"홍길동"}` | body | 저장 후 그대로 200 |
| 값 부족 | - | 400 "필수 요청값을 입력해주세요." |
| 타입/형식 오류 (year 4자리 숫자, name 문자열) | - | 400 "올바르게 입력해주세요." |
| 그 외 메서드 | - | 405 "잘못된 요청입니다." |

---

## 1. DynamoDB 테이블

**DynamoDB → 테이블 생성**:
- 이름 `wsc2026-worldschool-table`
- 파티션 키 `admission_year` (**숫자 N**)
- 정렬 키 `student_name` (**문자열 S**)
- 생성 후 → 테이블 → 추가 설정 → **삭제 방지(Deletion protection) 켜기**

## 2. Lambda Layer (env 파일)

로컬에서 레이어 zip 구성 (경로 중요: `python/.env`):
```
layer/
└── python/
    └── .env        # 내용: tableName=wsc2026-worldschool-table
```
- `.env`에 `tableName=wsc2026-worldschool-table` 저장
- `layer` 폴더를 zip (`python/.env` 구조가 zip 루트에 오도록)
- **Lambda → 계층 → 계층 생성**:
  - 이름 `wsc2026-worldschool-env-layer`
  - zip 업로드, 호환 런타임 Python 3.x → 생성

> 코드에서 `load_dotenv("/opt/python/.env")` 로 읽음 (레이어는 `/opt`에 마운트).
> python-dotenv도 필요하므로 레이어 `python/`에 `dotenv` 패키지도 포함하거나, 배포 zip에 포함.

## 3. Lambda 함수

**Lambda → 함수 생성**:
- 이름 `wsc2026-worldschool-management`, 런타임 Python 3.12
- 실행 역할: DynamoDB 접근 권한 있는 역할 (`dynamodb:GetItem/PutItem/Scan` on 테이블)
- 생성 후:
  - **계층 추가** → `wsc2026-worldschool-env-layer`
  - 코드: 배포파일 `lambda.py` 업로드 (핸들러 `lambda.lambda_handler`)

> ⚠️ 배포파일 `lambda.py`는 `json.dumps(..., default=str)`라 `admission_year`가 문자열로 나가 채점 4-6 실패.
> **Decimal → 숫자 변환**을 넣어야 함:
> ```python
> from decimal import Decimal
> def _json_default(o):
>     if isinstance(o, Decimal): return int(o) if o % 1 == 0 else float(o)
>     raise TypeError
> # json.dumps(..., default=_json_default, ensure_ascii=False)  로 3곳 교체
> ```

## 4. API Gateway (REST, ANY, Lambda 프록시)

**API Gateway → REST API → 구축**:
- 이름 `wsc2026-worldschool-api`
- 리소스: **루트(/)에 메서드 대신 ANY** 생성
  - 리소스 `/` 선택 → 메서드 생성 → **ANY**
  - 통합 유형: **Lambda 함수**, **Lambda 프록시 통합 사용** 체크
  - Lambda: `wsc2026-worldschool-management`
  - 저장 (권한 추가 팝업 확인)
- (필요시 `{proxy+}` 리소스에도 ANY + 프록시 통합)
- **API 배포**: 스테이지 이름 `wsc2026-worldschool-api-stage`

배포 후 호출 URL:
`https://<api-id>.execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage`

---

## 5. 동작 확인 (채점 4-6)
```bash
API_ID=$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text)
URL=https://${API_ID}.execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage

# POST → 저장
curl -L -X POST -d '{"admission_year": 2026, "student_name":"홍길동"}' -w "\n%{http_code}\n" $URL
# GET 전체 → [{"student_name":"홍길동","admission_year":2026}]  (year가 숫자여야 함!)
curl -L -X GET -w "\n%{http_code}\n" $URL | jq .
# GET 특정
curl -L -G -d "admission_year=2026" --data-urlencode "student_name=홍길동" -w "\n%{http_code}\n" $URL
# 검증: 값부족 400, 타입오류 400, 없는항목 404, DELETE 405
```

## 자주 나는 오류
- **4-6에서 `admission_year`가 `"2026"`(문자열)** → Decimal 미변환. 3단계 `_json_default` 적용
- **`No module named dotenv`** → 레이어에 python-dotenv 미포함. 레이어 `python/`에 설치해 재업로드
- **`tableName` None** → 레이어 `.env` 경로가 `python/.env` 아님, 또는 `load_dotenv` 경로 오류
- **`{ANY: {}}`** 출력은 정상 (루트 리소스의 ANY 메서드). 채점 영향 없음
- **삭제 방지 확인 실패(4-4 true)** → 테이블 Deletion protection 켜기
