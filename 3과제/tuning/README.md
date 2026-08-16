# tuning/ — 부하 측정 · 응답규약 검증 · 자동 튜닝

3과제 40점은 **전부 부하 테스트 결과**로 매겨진다. 이 폴더는 채점과 같은 방식으로 미리 재보고,
어디를 고칠지 정해주는 도구 모음이다. Windows PowerShell 기준.

| 채점 항목 | 배점 | 확인 도구 |
|---|---|---|
| 비정상 요청 처리 (403/404) + 이미지 다운로드 | 4 | **`verify.ps1`** |
| 가용성 (user/product/stress) | 12 | `loadtest.ps1` |
| 성능 (user·product ≤0.2s, stress ≤1.0s) | 12 | `loadtest.ps1` |
| 비용 (노드 수) | 12 | `loadtest.ps1` 의 nodes + `autotune.ps1` |

---

## 파일

| 파일 | 역할 |
|---|---|
| `setup.ps1` | `hey.exe`·`kubectl.exe` 설치(`%USERPROFILE%\bin`) + kubeconfig 작성 |
| `config.ps1` | **대회날 여기만 고친다.** 엔드포인트·API 목록·SLO·게이트 |
| `verify.ps1` | 응답코드 규약 검증 (정상 2xx / 비정상 403 / 미정의 404 / 이미지 200) |
| `loadtest.ps1` | 채점 방식 부하 측정 → 리포트 + 권장값 |
| `autotune.ps1` | cpu/HPA 조합 스윕 → 최고 조합 자동 적용 |
| `score.py` | hey CSV 채점기 (`loadtest`/`autotune` 이 호출) |
| `advise.py` | 측정 + 라이브 상태 → 앱별 늘려/줄여/유지 판정 |
| `waf_header_stats.py` | WAF 로그 분석 → 아직 안 막힌 비정상 패턴 + tfvars 제안 |

---

## 빠른 시작

```powershell
cd C:\Users\competitor\2026-terraform\3과제\tuning
Set-ExecutionPolicy -Scope Process Bypass -Force      # 스크립트가 막히면

.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2
kubectl -n app get pods                               # 클러스터 보이는지

.\verify.ps1                                          # 1) 응답규약 4점 먼저
.\loadtest.ps1 -Duration 180s -Label baseline          # 2) 가용성/성능/노드 측정
.\autotune.ps1 -App stress -Duration 90s               # 3) 병목 앱만 정밀 튜닝
```

엔드포인트는 자동으로 `..\terraform` 의 `terraform output -raw endpoint` 에서 읽는다.
다른 주소를 쓰려면 `-Url http://...` 또는 `$env:ENDPOINT`.

> `hey` 가 깨져서 결과가 전부 `NO DATA` 로 나오면: `(Get-Item $env:USERPROFILE\bin\hey.exe).Length`
> 가 1MB 미만이면 손상이다. 삭제 후 `winget install --id GoLang.Go -e` → 새 창 →
> `$env:GOBIN="$env:USERPROFILE\bin"; go install github.com/rakyll/hey@latest`.

---

## config.ps1 — 대회날 고치는 곳

```powershell
$APIS = @(
  @{ name = 'user';    slo = 0.2; conc = 30; qps = 10; method = 'GET';  path = "/v1/user?email=...";  body = $null }
  @{ name = 'product'; slo = 0.2; conc = 30; qps = 10; method = 'GET';  path = "/v1/product?id=...";  body = $null }
  @{ name = 'stress';  slo = 1.0; conc = 12; qps = 2;  method = 'POST'; path = '/v1/stress';          body = '...' }
)
```

| 항목 | 의미 |
|---|---|
| `name` | 결과 라벨 + `autotune -App` 대상 Deployment 이름 |
| `slo` | 채점기준의 성능 SLO(초). 이 이내면 perf OK |
| `conc`/`qps` | `hey -c` / `-q` |
| `$SEEDS` | 측정 전에 넣어둘 레코드 (GET 부하가 실제 행을 맞히도록) |
| `$AVAIL_GATE` | 가용성 합격선(99%). 미달 조합은 autotune 에서 실격 |
| `$COST_BASELINE_NODES` | **비용 패널티 기준 노드 수. terraform `node_desired_size` 와 맞춰야 한다** |
| `$COST_PENALTY` | 기준 초과 노드 1대당 감점 |

⚠ **API 경로/스펙이 바뀌면 `$APIS`·`$SEEDS`·`$HC_PATH`·`$IMAGES_PREFIX` 를 새 스펙으로 고친다.**
terraform 변수를 바꿔도 여기는 자동 반영되지 않는다.

⚠ `$COST_BASELINE_NODES` 가 실제 baseline 과 다르면 autotune 이 엉뚱한 조합을 우승으로 뽑는다.
terraform 이 `node_desired_size = 1` 이면 여기도 1.

---

## verify.ps1 — 응답규약 4점

부하와 무관하게 **응답코드가 규약대로 나오는지** 본다. 트래픽 시작 전에 반드시 통과시켜야 한다.

```powershell
.\verify.ps1
.\verify.ps1 -SkipImage      # S3/자격증명 조회가 안 될 때
```

| 그룹 | 기대 | 내용 |
|---|---|---|
| A | 2xx | healthcheck + `$APIS` 정상 요청 |
| B | 403 | 유효 경로 + 스캐너 UA / 쓰레기 헤더 / 위조 XFF / 경로탐색 / 인젝션 body |
| C | 404 | `/v1/none`, `/.env`, `/admin`, `/v1/users` — **403 이면 오답** |
| D | 200 | S3 에 프로브 오브젝트를 넣고 CloudFront 경유 GET + **본문 일치까지** 확인 |
| E | 403 | ALB 직접 호출 차단 (정보성) |

FAIL 이면 스크립트가 원인별 처방을 같이 출력한다. 실패 시 종료코드 1.

- **A 실패** → 앱/DB 문제. 가용성 12점이 같이 죽으니 최우선
- **B 실패** → WAF 룰 미적용. `variables.tf` 의 `waf_blocked_*` 확인 후 apply
- **C 가 403** → 커스텀 룰 scope 과다. `locals.tf` 의 `waf_block_scope_regex` 확인
- **D 실패** → S3 OAC / CloudFront `/images` 동작 / `strip_images_prefix` 함수 확인

---

## loadtest.ps1 — 가용성/성능/비용 측정

```powershell
.\loadtest.ps1 -Duration 180s -Label baseline
```

모든 API 를 `hey` 로 **병렬** 부하하고, 5초 간격으로 노드/파드 수를 샘플링한다.
끝나면 `score.py report` 리포트와 `advise.py` 권장값이 이어서 나온다.

```
api             n  avail%  perf%     p50     p95     p99     max
user         1800  100.0%  98.2%   0.041   0.180   0.240   0.900
product      1800  100.0%  99.9%   0.012   0.030   0.050   0.210
stress        360   99.7%  95.0%   0.400   0.950   1.400   2.100
nodes      min=1 max=4 avg=2.30  (baseline=1, 초과분 1.30 대가 비용 패널티)
```

| 열 | 의미 | 판단 |
|---|---|---|
| `avail%` | 5초 내 2xx 비율 = 채점 2번 | **99% 미만이면 다른 건 다 무시하고 용량부터** |
| `perf%` | SLO 이내 비율 = 채점 3번 | 목표 구간(90/87.5/85…)이 0.5점 단위 |
| `p95`/`p99` | 꼬리지연 | `p95 > slo` 면 perf% 가 곧 무너진다 |
| `nodes avg` | 채점 4번 비용 대리지표 | 낮을수록 좋지만 avail 을 깎으면 손해 |

`NO DATA` 는 측정 실패다(hey 손상 또는 엔드포인트 오류). 숫자가 나쁜 게 아니라 **안 재진 것**이니
먼저 고쳐야 한다.

---

## advise.py — 앱별 판정

`loadtest.ps1` 끝에서 자동 실행된다. 측정값 + 라이브 설정(cpu request, HPA util/min/max, 현재 CPU%)을
합쳐 앱마다 판정하고, 즉시 적용 명령과 terraform 반영값을 같이 출력한다.

| 우선순위 | 조건 | 판정 |
|---|---|---|
| 1 | `avail < 99%` | **늘려** — cpu×1.5, min+1, util−5 (비용은 나중) |
| 2 | `perf < 95%` 또는 `p95 > SLO` | **늘려** — cpu×1.4, util−10 (꼬리지연) |
| 3 | `perf ≥ 99.5%` + 현재CPU ≪ 목표 | **줄여** — cpu×0.75, util+10 (과투자) |
| 4 | 그 외 | 유지 |

`kubectl set resources` / `patch hpa` 는 **임시**다(재배포 시 사라짐). 확정된 값은
`terraform/k8s_apps.tf` 의 해당 앱 `requests.cpu` / HPA `average_utilization`·`min_replicas` 에 박고
`terraform apply`.

---

## autotune.ps1 — 조합 스윕

```powershell
.\autotune.ps1 -App stress -Duration 90s    # 권장: 병목 앱만
.\autotune.ps1 -Duration 90s                # 전체 앱 균일 (방향 탐색용)
```

6개 조합(cpu × HPA util × min/max)을 돌려 `perf − 비용패널티 (+ avail 게이트)` 로 점수화하고,
최고 조합을 라이브에 다시 적용한 뒤 terraform 반영값을 출력한다.

각 조합 측정 전에 **노드가 baseline 으로 회수될 때까지 기다린다**(최대 3분). 이전 조합이 띄운
노드가 남아 있으면 `nodes_avg` 가 부풀어 비용 점수가 뒤섞이기 때문이다.

**`-App` 없이 돌린 우승값을 그대로 쓰지 말 것.** 전체 앱에 같은 값을 밀어넣은 결과라서, 앱마다
부하 성격(user/product = DB I/O, stress = CPU)이 달라 최적값이 다르다. 방향만 보고, 확정은
`-App` 으로 앱별로 한다.

6조합 × 90초 + 대기 ≈ 15~20분이다. 트래픽 시작 후에는 시간이 없으니 **트래픽 전에** 돌린다.

---

## waf_header_stats.py — 안 막힌 비정상 찾기

```powershell
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

WAF 로그를 헤더 키/값 × 엔드포인트 × action × status 로 집계해서, **판정상 403 이어야 하는데
WAF 가 ALLOW 한 요청**을 뽑아준다. tfvars 제안까지 출력한다. (CloudFront scope WAF 라 로그는 us-east-1)

제안을 `terraform/terraform.tfvars` 에 넣고 apply. ⚠ 리스트 변수는 **덮어쓰기**라 기본값 + 새 값을
전부 나열해야 한다. 적용 후 `verify.ps1` 로 403/404 가 그대로인지 재확인.

---

## 대회날 순서

| 시점 | 할 일 |
|---|---|
| 배포 직후 | `.\verify.ps1` — 응답규약 4점 확보 (여기서 FAIL 이면 다른 것보다 먼저) |
| 트래픽 전 | `.\loadtest.ps1 -Duration 180s -Label baseline` → 병목 앱 확인 |
| 트래픽 전 | `.\autotune.ps1 -App <병목앱>` → 값 확정 → `k8s_apps.tf` 반영 후 apply |
| 트래픽 중 | `python waf_header_stats.py ...` → 새 패턴 차단 → `.\verify.ps1` 재확인 |
| 트래픽 중 | `.\loadtest.ps1 -Label during` 로 추세 확인 (부하가 겹치니 짧게) |

**원칙**: `avail%` < 99 면 비용·성능보다 **무조건 용량 먼저**. 가용성 12점과 성능 12점은
avail 이 깨지면 동시에 무너진다. 한 번에 한 앱만 바꿔야 원인 추적이 된다.
