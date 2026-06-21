# apdev practice-app

전국기능경기대회 클라우드컴퓨팅 제3과제(System Operation) 연습용 어플리케이션.

`user`, `product`, `stress`는 **각각 독립된 Go 모듈**입니다. 같은 디렉토리 안에 모아둔 건 편의일 뿐, 서로 코드 의존성이 없어요. 각자 자기 `go.mod`로 빌드되고 자기 단위테스트를 가집니다.

```
practice-app/
├── user-app/        ← github.com/practice/apdev-user
│   ├── go.mod
│   ├── main.go
│   ├── handler/
│   ├── db/
│   └── model/
├── product-app/     ← github.com/practice/apdev-product
│   ├── go.mod
│   ├── main.go
│   ├── handler/
│   ├── db/
│   ├── model/
│   └── storage/     ← SDK + s3fs 두 구현
├── stress-app/      ← github.com/practice/apdev-stress
│   ├── go.mod
│   ├── main.go
│   ├── handler/
│   └── model/
├── migrations/         ← MySQL init SQL (공용 스키마)
├── localstack-init/    ← LocalStack 부팅 시 버킷 생성
├── docker-compose.yml  ← MySQL + LocalStack S3
├── build.sh            ← linux/amd64 크로스컴파일
└── dist/               ← 빌드 산출물 (gitignore 권장)
```

## 1. 인프라 기동

```bash
docker compose up -d
```

- MySQL 8.0 (`localhost:3306`, 계정: `appuser`/`apppass`, DB: `dev`)
- LocalStack S3 (`localhost:4566`, 버킷: `apdev-product-images` 자동 생성)
- `migrations/001_init.sql`이 부팅 시 `user`/`product` 테이블을 만듭니다.

## 2. 각 앱 빌드 & 실행

### 로컬 개발 (mac/Linux 네이티브)

```bash
# user 앱
go -C user-app build -o ../bin/user .
MYSQL_USER=appuser MYSQL_PASSWORD=apppass \
MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_DBNAME=dev \
./bin/user

# product 앱 (SDK 모드)
go -C product-app build -o ../bin/product .
MYSQL_USER=appuser MYSQL_PASSWORD=apppass MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_DBNAME=dev \
STORAGE_MODE=sdk \
S3_BUCKET=apdev-product-images S3_REGION=ap-northeast-2 \
S3_ENDPOINT=http://localhost:4566 S3_PATH_STYLE=true \
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
./bin/product

# stress 앱
go -C stress-app build -o ../bin/stress .
./bin/stress
```

### EC2/EKS 배포용 — linux/amd64

```bash
./build.sh              # → dist/user, dist/product, dist/stress (ELF, static, stripped)
GOARCH=arm64 ./build.sh # arm64로 빌드하고 싶을 때
```

산출물은 **정적 링크 + stripped**라 Amazon Linux 2023, Alpine, scratch 어디든 그대로 실행됩니다. PDF가 명시한 환경(`x86 EC2 / Amazon Linux 2023`)과 일치.

```bash
# 검증 완료 - Amazon Linux 2023 amd64 컨테이너에서 직접 실행됨
$ file dist/user
dist/user: ELF 64-bit LSB executable, x86-64, statically linked, stripped
```

## 3. product 앱 — S3 두 가지 방식

`STORAGE_MODE` 환경변수로 스위칭.

### A. SDK 방식 (`STORAGE_MODE=sdk`)  ★ 권장

`aws-sdk-go-v2`로 `s3.PutObject` / `s3.GetObject` 직접 호출. EKS에선 보통 **IRSA(IAM Roles for Service Accounts)** 로 권한 부여.

```bash
STORAGE_MODE=sdk \
S3_BUCKET=apdev-product-images \
S3_REGION=ap-northeast-2 \
# 아래 둘은 LocalStack/실제 AWS 분기:
# 실제 AWS면 둘 다 제거하고 IRSA로 권한 부여
S3_ENDPOINT=http://localhost:4566 \
S3_PATH_STYLE=true \
./bin/product
```

### B. s3fs(FUSE 마운트) 방식 (`STORAGE_MODE=s3fs`)

S3 버킷을 Pod에 파일시스템으로 마운트하고, 어플리케이션은 **`os.Create`/`os.Open` 같은 일반 파일 I/O만** 사용. AWS SDK 의존성 0.

```bash
STORAGE_MODE=s3fs \
S3FS_MOUNT_PATH=/mnt/s3 \
./bin/product
```

EKS에서 마운트하는 일반적인 방법:
1. **Mountpoint for Amazon S3 CSI Driver** (2024+ 권장) — AWS 공식 CSI. PVC만 만들면 됨.
2. **s3fs-fuse** — 노드에 직접 설치 + hostPath/DaemonSet. 레거시.

### 두 방식 비교

|  | **SDK** | **s3fs** |
|---|---|---|
| 코드 의존성 | aws-sdk-go-v2 | 표준 라이브러리만 |
| 인증 | IRSA (앱이 인지) | 노드/마운트가 처리 (앱은 모름) |
| 성능 | 매번 API call | OS 페이지캐시 활용 가능 (일관성 트레이드오프) |
| 에러 모델 | HTTP 코드 (`NoSuchKey`, throttling 등) | POSIX errno (`ENOENT`, `EIO`) |
| 부분 업로드 제어 | multipart 직접 제어 가능 | FUSE 레이어가 처리 (제어 X) |
| 이미지 업데이트 | `PutObject` (S3 의미상 전체 교체) | `open+write` 가능해 보이나 내부적으로 전체 재업로드 |
| 시험 적합도 | ★★★★★ (제어·디버깅 명확) | ★★ (마운트 실패 시 디버깅 어려움) |

**개인 추천**: 시험에선 SDK가 정답에 가까움. s3fs는 "어플리케이션 코드를 한 줄도 안 바꾸고 S3에 쓰고 싶다"는 레거시 마이그레이션 시나리오 외엔 잘 안 씁니다. 둘 다 만들어둔 건 시험 어떤 방식을 묻든 대응할 수 있게.

## 4. API 요약

| App | Method | Path | Body/Query |
|---|---|---|---|
| **user** | POST | `/v1/user` | JSON: requestid, uuid, username, email |
| **user** | GET | `/v1/user` | `?email=&requestid=&uuid=` |
| **product** | POST | `/v1/product` | JSON: requestid, uuid, id, name, price |
| **product** | GET | `/v1/product` | `?id=&requestid=&uuid=` |
| **product** | PUT | `/v1/product` | multipart: requestid, uuid, id, **image (file)** |
| **product** | GET | `/images/<key>` | (이미지 다운로드) |
| **stress** | POST | `/v1/stress` | JSON: requestid, uuid, length (1~4096) |
| 모두 | GET | `/healthcheck` | — |

## 5. 테스트

```bash
# 각 모듈별 단위 테스트
go -C user-app test ./...
go -C product-app test ./...
go -C stress-app test ./...
```

## 6. 정리

```bash
docker compose down -v   # MySQL 데이터까지 삭제
rm -rf dist bin
```

---

## 검증된 동작 흐름 (참고)

세 앱 모두 실제 MySQL/LocalStack과 연동되어 다음이 통과됨:

| 시나리오 | 결과 |
|---|---|
| user-app: POST → GET 라운드트립 | 201 / 200 ✓ |
| product-app SDK 모드: 생성 → 이미지 업로드 → LocalStack S3 확인 → 다운로드 | 모든 단계 ✓ (response `"storage":"sdk"`) |
| product-app s3fs 모드: 생성 → 이미지 업로드 → 마운트 경로 파일 확인 → 다운로드 | 모든 단계 ✓ (response `"storage":"s3fs"`) |
| stress-app: length=64 → 10ms, length=1024 → 100ms | 비례 응답 ✓ |
| `dist/*` linux/amd64 → Amazon Linux 2023 컨테이너 실행 | ELF static binary 정상 실행 ✓ |
