# testapp/ — 연습용 앱 (앱 교체 워크플로 익히기)

대회 스펙과 호환되는 **다른 구현**의 user/product/stress 앱 소스.
공식 바이너리(`application/binary/{user,product,stress}`) 대신 이걸 빌드해서 넣고
배포해 보면서 **"새 앱 바이너리 교체"** 절차를 연습하는 용도.

> 이건 소스(`.go`)다. 배포는 **바이너리**로 이뤄지므로(build.tf가 `binary/`만 씀),
> 아래처럼 **linux/amd64 로 빌드해서 `binary/` 에 복사**한 뒤 apply 한다.

## 스펙 (공식과 동일한 계약)

| 앱 | 엔드포인트 | 특징 |
|---|---|---|
| user    | `POST/GET /v1/user`, `/healthcheck` | MySQL `user(id,username,email)`. `USER_DELAY_MS` 로 인공 지연 |
| product | `POST/GET/PUT /v1/product`, `/healthcheck` | MySQL + S3 업로드 + GET 캐시(10s) |
| stress  | `POST /v1/stress`, `/healthcheck` | length 비례 CPU 부하. `STRESS_MULT`(기본 400)로 강도 조절 |

- 환경변수·테이블·포트(8080)는 인프라(`k8s_base.tf`)와 그대로 맞춰져 있어 **교체만 하면 동작**.
- 접근로그를 JSON 으로 stdout 에 찍어 `tools/` 대시보드가 바로 파싱한다.

## 1. 빌드 (Windows PowerShell, Go 설치 필요)

`application/` 폴더에서 (기존 `go.mod`/`go.sum` 재사용, 별도 의존성 설치 불필요):

```powershell
cd C:\Users\competitor\2026-terraform\3과제\application
$env:GOOS='linux'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
go build -o binary\user    .\testapp\user
go build -o binary\product .\testapp\product
go build -o binary\stress  .\testapp\stress
$env:GOOS=''; $env:GOARCH=''; $env:CGO_ENABLED=''   # 환경변수 원복
```

> 이 순간 `binary/{user,product,stress}` 가 **연습용 앱으로 교체**된다.
> (build.tf 가 바이너리 hash 변화를 감지 → 다음 apply 에서 새 이미지 빌드·롤링 배포)

## 2. 배포 (교체 반영)

```powershell
cd ..\terraform
terraform apply -auto-approve -var "k8s_provider_ready=true" -var app_image_tag="v$([int](Get-Date -UFormat %s))"
```
- 바이너리가 바뀌었으므로 ECR 재빌드 + user/product/stress 파드 롤링 재배포.
- `app_image_tag` 를 새 값으로 줘야 롤아웃이 확실히 일어난다(README 루트 "앱 교체" 참고).

## 3. 검증

```powershell
kubectl -n app rollout status deploy/user
kubectl -n app rollout status deploy/product
kubectl -n app rollout status deploy/stress

$EP = (terraform output -raw endpoint)
curl.exe -s "$EP/healthcheck"
curl.exe -s -X POST -H "Content-Type: application/json" `
  -d '{"requestid":"1","uuid":"u1","username":"t1","email":"t1@example.org"}' "$EP/v1/user"      # 201
curl.exe -s "$EP/v1/user?email=t1@example.org&requestid=1&uuid=u1"                                # 200
curl.exe -s -X POST -H "Content-Type: application/json" `
  -d '{"requestid":"1","uuid":"u1","length":128}' "$EP/v1/stress"                                 # 201
```

## 4. 원래 공식 바이너리로 복원

교체 연습이 끝나면 git 으로 원본 복원:

```powershell
cd C:\Users\competitor\2026-terraform
git checkout -- "3과제/application/binary/user" "3과제/application/binary/product" "3과제/application/binary/stress"
# 다시 apply (새 태그로) 하면 공식 앱으로 롤백
```

> ⚠️ `binary/` 의 공식 바이너리는 git 에 있으니 위 명령으로 언제든 되돌릴 수 있다.
> 연습용 앱을 커밋하지 않는 한 원본은 안전하다.

## 튜닝 연습과 함께

stress 는 일부러 CPU 를 태우므로 `tuning/` 도구로 병목을 만들기 좋다:
```powershell
cd ..\tuning
.\loadtest.ps1 180s baseline     # stress 가 느리게 나옴 → advise 가 "cpu 늘려" 판정
.\autotune.ps1 -App stress       # 자동으로 최적 cpu/util 탐색
```
- 더 세게/약하게: Deployment 에 `STRESS_MULT` env 를 조절하거나 소스에서 기본값 변경 후 재빌드.
