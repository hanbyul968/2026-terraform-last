# testapp/ — 연습용 앱

대회 스펙과 호환되는 **다른 구현**의 user/product/stress 앱 소스.
공식 바이너리(`application/binary/`) 대신 이걸 빌드해서 넣고 배포하며
**앱 교체 절차를 직접 연습**하는 용도. (방법은 스스로 찾아서 해볼 것)

## 스펙 (공식과 동일한 계약)

| 앱 | 엔드포인트 | 특징 |
|---|---|---|
| user    | `POST/GET /v1/user`, `/healthcheck` | MySQL `user(id,username,email)`. `USER_DELAY_MS` 인공 지연 |
| product | `POST/GET/PUT /v1/product`, `/healthcheck` | MySQL + S3 업로드 + GET 캐시(10s) |
| stress  | `POST /v1/stress`, `/healthcheck` | length 비례 CPU 부하. `STRESS_MULT`(기본 400) |

- 환경변수(`MYSQL_*`, `S3_BUCKET`)·테이블·포트(8080)는 인프라와 맞춰져 있어 **교체만 하면 동작**.
- 접근로그를 JSON 으로 stdout 에 출력 → `tools/` 대시보드가 파싱.
- 소스(`.go`)다. 배포는 바이너리로 이뤄지니 스스로 linux/amd64 로 빌드해 넣어야 한다.
- 공식 바이너리는 git 에 있으니 언제든 되돌릴 수 있다.
