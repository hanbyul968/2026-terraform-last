# tuning/ — 공식 채점 · 라이브 Kubernetes 자동 튜닝

3과제 40점은 **전부 부하 테스트 결과**로 매겨진다. Dashboard 계산/튜닝 탭,
`advise.py`, `optimize.py`, `score.py`는 모두 **`rubric.py` + `tuning_engine.py` 한 엔진**을 쓴다.

> **기본 목표는 비용 우선(`-Objective cost`)이다.** 공식 채점에서 가용성은 `≥90%`면 앱당 만점이고,
> 성능은 `<30%`일 때만 비용 12점이 0이 된다. 다만 성능 점수 자체가 0.5점 단위로 깎이므로 유지선은
> **가용성 ≥90% · 성능 ≥80%**로 두고, 그 안에서 노드를 줄여 비용 점수를 챙긴다.
> 성능을 최대한 지키려면 `-Objective balanced`(가용성 99% 유지)로 실행한다.
>
> **request는 실측 사용량에서 벗어나지 않는다.** 파드당 실사용의 절반이 하한이고, 한 회차에
> 현재값의 절반 아래로는 내리지 않는다. 1800m을 쓰는 파드에 50m을 예약하는 비현실적인 값이
> 나오지 않게 하는 장치다. 더 내려야 하면 실측 후 다음 회차가 이어서 내린다.
>
> **부하량에 정규화해서 계산한다.** 부하를 세게 넣고 측정했다고 request가 과대해지면 안 되므로,
> 부하와 무관한 값인 **요청당 CPU 시간**을 구해 목표 부하에 곱한다.
> `필요 CPU = 요청당 CPU × 목표 rps`, `request = 필요 CPU ÷ 파드수`.
> 목표 부하는 `-LoadScale`(측정 부하 배수) 또는 `-TargetRps user=100,stress=10`으로 지정한다.
> 실측 예(2026-08-20): 요청당 CPU가 `stress 452ms`, `user 20ms`, `product 0.2ms`.
> 같은 클러스터에서 `-LoadScale 1.0`이면 3노드·stress 175m, `0.5`면 2노드·125m가 나온다.
>
> **한 회차에 여러 앱을 함께 적용한다(`bundle`).** 회차당 4~5분이라 앱별로 나누면 예산이 한 앱에서
> 끝난다. 상위 후보 배치에서도 한 앱이 3회를 독식하지 못하게 앱을 한 번씩 먼저 배정한다.

> **Source of truth는 Terraform 파일이 아니라 라이브 Deployment/HPA다.** 튜닝 명령은 현재 라이브
> request/target/min/max를 읽어 적용하고 같은 snapshot으로 정확히 롤백한다. Terraform drift는 정상이며,
> 튜닝 루프에 `terraform apply`를 넣지 않는다. request 변경은 rollout이므로 공식 트래픽 전에만 한다.

> ⏱ **18분 하드 상한:** warmup 60초(점수 제외) → baseline 120초 → 후보 최대 3개 × 120초.
> 각 후보 전에 settle과 150초 롤백 여유를 계산해 시간이 부족하면 새 시험을 열지 않는다.

| 채점 항목 | 배점 | 확인 도구 |
|---|---|---|
| 비정상 요청 처리 (403/404) + 이미지 다운로드 | 4 | **`verify.ps1`** |
| 가용성 (user/product/stress) | 12 | `loadtest.ps1` |
| 성능 (user·product ≤0.2s, stress ≤1.0s) | 12 | `loadtest.ps1` |
| 비용 (노드 수) | 12 | `loadtest.ps1` 의 nodes + `autotune.ps1` / **`optimize.ps1`(닫힌 루프)** |

---

## 파일

| 파일 | 역할 |
|---|---|
| `setup.ps1` | `hey.exe`·`kubectl.exe` 설치(`%USERPROFILE%\bin`) + kubeconfig 작성 |
| `config.ps1` | **대회날 여기만 고친다.** 엔드포인트·API 목록·SLO·게이트 |
| `verify.ps1` | 응답코드 규약 검증 (정상 2xx / 비정상 403 / 미정의 404 / 이미지 200) |
| `loadtest.ps1` | 채점 방식 부하 측정 → 리포트 + 권장값 (+ `podcpu.csv` 실사용 기록) |
| `autotune.ps1` | 완료된 부하 결과로 requests.cpu + HPA min/max/target 권장값만 계산(자동 변경 없음) |
| `optimize.ps1` | **18분 트랜잭션 runner** — warmup/baseline/최대 3후보 실측, 채택 또는 정확한 snapshot 롤백 (`-Apply` 없으면 제안만) |
| `rubric.py` | 공식 rate band·비용 ratio·성능 게이트의 단일 구현 |
| `tuning_engine.py` | 라이브 snapshot, 병목 분류, request/HPA 결합, 예약 기준 노드·CPU 경합 예측, 후보·명령 생성 |
| `optimize.py` | 공통 엔진 후보를 PowerShell runner에 JSON으로 전달하는 adapter |
| `score.py` | `rubric.py` 기반 hey CSV 호환 CLI (`report`/`score`) |
| `advise.py` | 공통 엔진의 read-only 설명 adapter — 공식 점수, 병목, 적용/롤백 명령 출력 |
| `waf_header_stats.py` | WAF 로그 분석 → 아직 안 막힌 비정상 패턴 + tfvars 제안 |

---

## 빠른 시작

```powershell
cd C:\Users\competitor\2026-terraform\3과제\tuning
Set-ExecutionPolicy -Scope Process Bypass -Force      # 스크립트가 막히면

.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2
kubectl -n app get pods                               # 클러스터 보이는지

.\verify.ps1                                        # 1) 응답규약 4점 먼저
.\loadtest.ps1 -Duration 120s -Label baseline       # 2) 가용성/성능/노드 측정 (~2.5분)
.\optimize.ps1 -Apply                               # 3) 18분 안에서 라이브 request/HPA 공식점수 최적화
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
terraform 이 `node_desired_size = 2` 이므로 여기도 **2**, `advise.py`/`score.py` 의
`TUNE_BASELINE_NODES` 도 2 다. 채점기준의 비용도 `평균 EC2 대수 ÷ 기준 2대` 로 계산된다.
`node_desired_size` 를 바꾸면 세 곳을 같이 바꿔야 한다.

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
.\loadtest.ps1 -Duration 120s -Label baseline
```

모든 API 를 `hey` 로 **병렬** 부하하고, 5초 간격으로 노드/파드 수와 **파드별 CPU 실사용**을
샘플링한다. 끝나면 `score.py report` 리포트(+ **실제 채점 환산**)와 `advise.py` 권장값이 이어서 나온다.

결과 폴더(`%TEMP%\tune-<label>`)에 남는 것:

| 파일 | 내용 | 쓰는 곳 |
|---|---|---|
| `<앱>.csv` | hey 원본 (상태코드, 응답시간) | 가용성·성능 채점 |
| `nodes.csv` | `ts,노드수,Running파드수` | 비용 지표(노드 수 평균) |
| `podcpu.csv` | `ts,파드명,cpu(밀리코어)` | **request 산정의 유일한 근거** |

`podcpu.csv` 가 필요한 이유는 request 권고가 실사용 피크에서 나오기 때문이다. 부하가 끝난 뒤
`kubectl top` 을 한 번 찍으면 그 순간값이 피크로 잡혀 과대·과소 권고가 난다. 창 전체를 남겨야
p90/p95 를 제대로 계산할 수 있다. `metrics-server` 가 없으면 이 파일만 비고 가용성·성능 측정은 정상이다.

⚠ **같은 `-Label` 로 다시 돌리면 시작 시 그 폴더의 csv 를 지운다.** `nodes.csv`·`podcpu.csv` 는
append 로 쓰기 때문에 안 지우면 옛 표본이 쌓인다. 실측 사고: autotune 조합 이름이 과거 수동
라벨과 같아 `tune-baseline/nodes.csv` 에 **35일치 3,423 표본**이 누적됐고 비용 비율이 틀리게 나왔다.

⚠ **노드 수 표본이 `0` 이면 버린다.** 노드 0대는 존재하지 않으므로 그 값은 `kubectl` 조회 실패다.
평균에 섞이면 비용을 실제보다 좋게 만든다(실측: 3,399 중 1,370개가 0 → 평균 2.28대로 보였지만
실제 3.82대, 비용 11점 vs 8점).

```
api             n  avail%  perf%     p50     p95     p99     max
user         5311   99.2%  52.2%   0.183   1.795   4.230  10.294
product     26280  100.0%  99.7%   0.010   0.021   0.048   2.678
stress        877   98.2%  57.1%   0.812   3.434   5.724   7.751
nodes      min=1 max=9 avg=3.82  (baseline=2, cost ratio 1.91)

채점 환산       avail%    가용성   perf%    성능
product     100.0%    4.0   99.7%   4.0
stress       98.2%    4.0   57.1%   1.0
user         99.2%    4.0   52.2%   1.0
합계                  12.0/12          6.0/12
비용         ratio 1.91 -> 8.0/12
소계         26.0/36  (+ 비정상요청 4점은 verify.ps1 로 확인)
```

### 채점 환산 (score.py)

채점기준표를 그대로 옮겨 계산한다. 실제 채점 결과(가용성 12.0 / 성능 6.5 / 비용 6.0)를
정확히 재현하는 것으로 검증했다.

| 항목 | 계산 |
|---|---|
| 가용성 12점 | 앱별 availability 가 90/87.5/85/82.5/80/70/50/30% 를 넘을 때마다 0.5점 (앱당 최대 4점) |
| 성능 12점 | 앱별 performance 도 같은 구간 (앱당 최대 4점) |
| 비용 12점 | cost ratio 가 1.00/1.25/…/3.75 이하일 때마다 1점 |
| 비정상요청 4점 | `verify.ps1` 영역이라 여기서는 계산하지 않는다 |

**비용 12점에 걸린 두 개의 함정**

- `cost ratio ≥ 0.50` 이어야 한다. 노드를 과도하게 줄여 0.5 미만이면 **비용 0점**이다.
- **세 앱 performance 가 모두 30% 이상**이어야 한다. 하나라도 미달이면 **비용 12점 전부 0점**이다.

즉 성능은 비용의 전제조건이다. 성능을 깎아 비용을 얻는 트레이드오프는 30% 선 아래에서 성립하지
않는다. 가용성은 최상위 구간이 `≥90%` 라 90%만 넘기면 앱당 만점이다.

| 열 | 의미 | 판단 |
|---|---|---|
| `avail%` | 5초 내 2xx 비율 = 채점 2번 | **99% 미만이면 다른 건 다 무시하고 용량부터** |
| `perf%` | SLO 이내 비율 = 채점 3번 | 목표 구간(90/87.5/85…)이 0.5점 단위 |
| `p95`/`p99` | 꼬리지연 | `p95 > slo` 면 perf% 가 곧 무너진다 |
| `nodes avg` | 채점 4번 비용 대리지표 | 낮을수록 좋지만 avail 을 깎으면 손해 |

`NO DATA` 는 측정 실패다(hey 손상 또는 엔드포인트 오류). 숫자가 나쁜 게 아니라 **안 재진 것**이니
먼저 고쳐야 한다.

---

## Dashboard 계산/튜닝 탭

```powershell
cd ..\tools
.\dashboard.ps1
# 변경된 앱/SLO 예: py -3 dashboard.py --namespace app --slos-ms checkout=200,worker=1000
```

Dashboard는 Deployment/HPA와 `app` label에서 앱을 발견한다. SLO는 기본 `config.ps1` 값 외에
Deployment `*/slo-ms` annotation, 컨테이너 `SLO_MS`, `APP_SLOS_MS`, `--slos-ms`로 덮어쓸 수 있다.
로그 지표도 공식식과 동일하게 availability=`2xx && ≤5s / 전체`, performance=`2xx && ≤SLO / 전체`다.
**계산** 탭은 공식 점수·게이트·실측 CPU 수요·예약 기준 노드·후보를, **튜닝적용** 탭은 각 후보의 라이브 적용과
정확한 rollback 명령을 보여준다. 대시보드는 자동 적용하지 않는다.

---

## advise.py — 비파괴 request/HPA 계산

`loadtest.ps1` 끝에서 자동 실행된다. 측정 결과, 활성 부하창의 Pod/노드 CPU, 라이브
Deployment/HPA 설정을 읽어서 앱별 `requests.cpu`, `min`, `max`, `target%` 권장값을 출력한다.
클러스터나 Terraform은 변경하지 않는다.

핵심 공식:

```text
파드당 HPA 발동점 = requests.cpu × target / 100
예상 replica      = clamp(ceil(활성창 총 CPU p90 / 발동점), min, max)
예상 노드         = ceil((시스템 예약 + 앱별 request × 예상 replica) / 노드 allocatable)
CPU 비중          = (총 CPU p90 ÷ 초당 요청수) ÷ 평균 지연
예상 지연         = 실측 지연 × (1 + (CPU 공급부족배수 − 1) × CPU 비중)
```

request는 CPU 제한이 아니라 **예약량**이다. 그래서 request를 올려도 파드가 빨라지지 않고, 대신
노드 예약이 늘어 비용만 오른다. 반대로 내리면 노드가 줄어 CPU 공급이 줄고 지연이 늘 수 있다.
엔진은 그 두 방향을 위 식으로 같은 공식 점수에 넣어 비교하며, 성능이 낮다는 이유만으로 request를
올리지 않는다. CPU 비중이 낮은 앱(DB 대기형·캐시 히트형)은 노드가 줄어도 지연이 거의 안 늘기
때문에 더 과감히 내릴 수 있다고 판단한다.

**양방향.** 비용 여유가 있으면 target을 올려 파드·노드를 줄이고, 게이트가 위험하면 target을 내려
빨리 확장한다. "어디까지 갈 수 있나"는 한 회차 측정으로 확정할 수 없으므로 `optimize.ps1`이
120초 실측으로 채택·롤백을 결정한다.

`podcpu.csv`와 `nodecpu.csv`는 반드시 `loadwindows.csv`의 start/end 안에 있는 표본만 사용한다.
이 필터가 UTC+9가 중복 적용된 표본과 부하 종료 후 유휴 표본을 제거한다. 백분위는 표본 수가 적어도
최댓값 보간에 끌려가지 않도록 nearest-rank 방식으로 계산한다.

```powershell
py -3 .\advise.py baseline --slos user=0.2,product=0.2,stress=1.0 --ns app
py -3 .\advise.py baseline --slos user=0.2,product=0.2,stress=1.0 --ns app --app user
```

출력은 다음 측정 회차를 위한 최대 3개의 공통 엔진 후보이며 각 후보에 **현재 라이브 값 기반 적용 명령과
정확한 롤백 명령**이 함께 나온다. 한 후보만 적용 → 120초 재측정 → 공식 소계가 오르고 두 게이트를
지키면 유지, 아니면 즉시 롤백한다. `advise.py` 자체는 read-only이고 클러스터를 변경하지 않는다.
여러 후보를 시간 제한 안에서 자동 검증하려면 `optimize.ps1 -Apply`를 쓴다. request 변경 후보는
Deployment rollout을 일으키므로 공식 트래픽 전에만 실행한다.

---

## autotune.ps1 — 비파괴 request + HPA 권장값 계산

`autotune.ps1`은 완료된 `loadtest` 결과와 라이브 설정을 **읽기만** 하고 다음 값을 계산한다.

```text
requests.cpu
minReplicas
maxReplicas
CPU averageUtilization
```

```powershell
# 먼저 측정
.\loadtest.ps1 -Duration 120s -Label baseline

# 전체 앱 권장값만 출력
.\autotune.ps1 -Result baseline

# 한 앱만 출력
.\autotune.ps1 -Result baseline -App user
```

이 스크립트는 legacy 붙여넣기 형식과의 호환을 위해 남아 있는 read-only 계산기다. 자동 변경은 하지
않으며, 공식 점수 기준 후보·예약 기준 노드 예측·정확한 롤백은 `advise.py` 또는 `optimize.ps1`을 사용한다.
출력을 적용하려면 Dashboard **튜닝적용** 탭에서 앱별 명령을 검토하고 라이브에 적용한다.

계산 원칙:

1. `loadwindows.csv`의 실제 활성 부하창에 해당하는 `podcpu.csv`/`nodecpu.csv` 표본만 사용한다.
   UTC+9 오염 표본과 부하 종료 후 유휴 표본은 버린다.
2. HPA의 실질 기준은 `requests.cpu × target%`인 파드당 목표 CPU다.
3. request는 예약량이라 파드 속도를 바꾸지 않는다. 노드 수는 예약량으로 정해지므로
   request는 비용에 직결된다. 성능이 낮다는 이유만으로 올리지 않는다.
4. request/target을 바꾸면 발동점(`request × target`)이 바뀌어 예상 replica가 달라진다.
   실측 p90 파드 수보다 적어지는 조합은 쓰지 않는다.
5. 활성창 총 CPU p90을 발동점으로 나눠 필요 replica를 계산한다. 라이브 `minReplicas`를
   임의로 2로 강제하지 않으며, startup/가용성 위험과 현재 min/max를 보존해 후보를 만든다.
6. 세 앱 중 하나라도 성능 30% 미만이면 비용 12점이 전부 0이므로 30% 게이트 복구가 우선이다.

권장값은 영구 정답이 아니라 **다음 측정 회차용 1-step 값**이다. 반영 후 시간이 남으면 다른 label로
120초 재측정해 확인한다. 여러 회차 자동 반복이 필요하면 `optimize.ps1`(18분 예산)이 그 역할을 한다.
앱·트래픽·바이너리가 바뀌면 이전 결과를 재사용하지 않는다.

## optimize.ps1 — 닫힌 루프 최적화 (공식 총점 최대화)

`advise.py`/`autotune.ps1`은 한 회차 측정으로 "1-step 권고"만 낸다. 그런데 **최적 HPA target은
한 번 측정으로는 알 수 없다** — target을 올리면 파드가 줄어 지연이 얼마나 늘지(성능%가 어느 밴드로
떨어질지)는 그 지점을 실제로 측정해야만 안다. `optimize.ps1`은 이걸 **측정→채점→조정→재측정**의
닫힌 루프로 푼다.

- 목적함수 = `rubric.py`의 **공식 가용성+성능+비용 소계(36점)**. 근사식이 아니다.
- 후보 = 게이트 복구 → 다음 성능 band → **실측 request/target 최적값** → 비용 회수. 앱 이름·SLO·트래픽·노드
  allocatable CPU를 snapshot마다 다시 읽고, 최대 3개만 실측한다.
- request와 HPA target은 실측으로 함께 계산한다. **request는 Pod 속도 상한이 아니다**(stress는
  CPU 바운드이고 limit이 따로 있다). 노드 수는 Karpenter가 보는 **예약량**으로 정해진다:
  `nodes = ceil((시스템 예약 + 앱별 request × 파드수) / 노드 allocatable)`.
- 노드가 줄면 CPU 공급이 줄어 지연이 늘고 성능/가용성 점수가 떨어진다. 이 저하를 **실측 응답시간
  분포를 공급 부족 배수만큼 늘려** 다시 채점해 비용 이득과 비교한다. 즉 비용만 보고 request를 깎지
  않고, 노드를 채우려고 request를 부풀리지도 않는다.
- **앱이 바뀌어도 가정하지 않는다.** 지연 중 CPU 처리 비중을
  `요청당 CPU 시간(총 CPU p90 ÷ 초당 요청수) ÷ 평균 지연`으로 매 측정에서 다시 구한다.
  CPU 바운드 앱은 노드 감소에 민감하게, DB 대기형·고정 지연형 앱은 둔감하게 평가된다.
  실측값 예(2026-08-20): `stress 0.65`, `user 0.13`, `product 0.02`.
  CPU 표본이 없으면(metrics-server 미설치 등) 보수적으로 1.0으로 보고 request 탐색을 건너뛴다.
- **탐색보다 나눗셈이 먼저다. 그리고 부하량으로 정규화한다.**
  `요청당 CPU = 총 CPU ÷ 초당 요청수` (부하량과 무관한 값) →
  `필요 CPU = 요청당 CPU × 목표 rps` → `request = 필요 CPU ÷ 파드수`.
  측정 당시 부하가 아니라 **목표 부하** 기준이므로, 부하를 세게 넣고 측정했다고 request가
  과대해지지 않는다. 목표 부하는 `-LoadScale`(측정 부하 배수, 기본 1.0) 또는
  `-TargetRps user=100,stress=10`으로 준다.
  실측 예(2026-08-20): 요청당 CPU `stress 452ms / user 20ms / product 0.2ms`,
  `-LoadScale 1.0` → 3노드·stress 175m, `0.5` → 2노드·125m, `0.25` → 1노드·75m.
- 같은 방식으로 **필요 노드 수와 앱별 예약을 즉시 계산**한다.
  `필요 노드 = ceil(목표 부하 필요 CPU / 노드당 가용 CPU)`,
  `앱별 request = (필요 노드 × 노드당 가용) × 앱 CPU 비중 ÷ 파드수`.
  노드당 가용은 `allocatable − DaemonSet 예약(노드당)`이다.
  실측 평균 노드가 이미 그 값이면 **request로는 비용을 더 줄일 수 없다**고 바로 알리고(`cost_locked`),
  노드 감소를 노린 후보는 시험하지 않는다. 회차 낭비를 막는 장치다.
- **request 하한은 실사용에 묶인다.** 파드당 필요 CPU의 절반 미만, 또는 현재값의 절반 미만으로는
  한 회차에 내리지 않는다. 1800m 쓰는 파드에 50m 같은 값이 나오지 않게 하는 장치다.
- **파드 수도 비용이다.** 노드 수는 CPU 예약과 **메모리 예약 중 큰 쪽**으로 정해진다.
  `노드 = max(ceil(Σ request×파드 / 노드당 가용 CPU), ceil(Σ 메모리요청×파드 / 노드 메모리))`.
  실측(2026-08-20): `user 32파드 × 128Mi = 4096Mi`, `product 20파드 × 128Mi = 2560Mi`로
  노드 메모리 `3292Mi` 기준 메모리만으로도 노드가 늘어난다.
- **발동점이 실사용보다 훨씬 낮으면 HPA는 항상 max에 붙어 탄력성이 없다.**
  실측: `user 100m × 25% = 25m`, `product 50m × 60% = 30m` 발동점 → 각각 32개·20개가 상시 유지.
  `pod-consolidate` 후보가 목표 부하 필요 CPU를 파드당 적정 크기로 나눠 파드 수·request·target·max를
  균형점으로 옮긴다(예: user 32파드 → 6파드, request 100m → 775m, target 25% → 90%, max 32 → 9).
  단 파드당 request가 올라가 CPU 예약이 늘 수 있어, 비용 우선 모드에서는 공식 점수가 떨어지면
  제안하지 않는다. 메모리가 병목이거나 `-Objective balanced`일 때 채택 후보로 올라온다.
- **유휴 노드는 baseline 노드그룹(고정 2대)을 넘으면 안 된다.** 노드 수는 총 예약 합이 아니라
  **AZ별 bin-packing**으로 정해진다. topology spread(zone maxSkew=1)가 앱 파드를 AZ에 흩으므로,
  AZ 노드 1대에 앉는 `Σ 앱 request`가 노드 가용 CPU(≈1480m)를 넘으면 그 AZ에 노드가 하나 더 뜬다.
  예: `user 600 + stress 750 + product 250 = 1600 > 1480` → AZ당 2노드 → 유휴 4노드가 대회날 부하
  없이도 상주(Karpenter 회수 불가). `idle-fit` 후보가 이를 감지해 min replica 파드가 baseline 노드에
  담기도록 request를 실사용 하한까지 비례 축소한다(부하 전 1회). baseline를 넘기는 다른 후보는 제외한다.
- **`optimize.ps1 -Apply`는 트래픽 전에 돌린다(0:40~0:58).** 두 단계로 동작한다:
  1. **부하 전 request 사이징 1회** — 유휴 노드가 baseline를 넘으면 `idle-fit`(AZ 노드에 min 파드가
     담기도록 request 축소), 아니면 실측 과소/과대 예약 교정을 **한 번** 적용한다(rollout 동반).
     값은 상수가 아니라 **그때 측정한 실사용·라이브 usable CPU로 계산**하므로 앱/트래픽이 바뀌어도
     맞는 값이 나온다. Terraform에 request 상수를 박아두지 않는다.
  2. **HPA-only 시행** — 이후 회차는 target/min/max만 즉시 조정(rollout 없음)한다.
  request 사이징은 트래픽 전 1회뿐이고, 실제 채점 트래픽(1:00~) 중에는 절대 request를 바꾸지 않는다.
- **request는 여유를 두고 낮게 잡는다.** 노드를 꽉 채우는 계산 최대치가 아니라 `REQUEST_HEADROOM`
  (기본 0.7, 30% 낮게)를 곱한 값을 쓴다. 이렇게 해야 앱·트래픽이 바뀌어도 유휴 파드가 baseline
  노드에 넉넉히 들어가고, 부족분은 HPA replica가 채운다. request는 예약량이라 낮아도 성능엔
  영향이 없다(파드는 limit까지 burst). 하한은 파드당 실사용의 절반이라 과소예약도 막는다.
- 선형 지연 모델을 신뢰할 수 있는 범위는 제한적이므로 한 회차 외삽은 공급 부족 1.5배까지만
  허용한다. 더 내려가야 하면 그 값을 120초 실측한 뒤 다음 회차가 이어서 판단한다.
- **목표 부하 필요 CPU보다 공급이 적어지는 노드 수는 균형 모드에서 제안하지 않는다.** 실측
  (2026-08-20): 4노드(공급 7720m < 수요 11122m)에서 가용성 게이트 실패, 6~7노드는 정상.
  하한을 채우려고 request를 올리지는 않는다(현재 예약이 더 낮으면 현재 노드 수가 하한).
  비용 우선 모드는 이 하한 대신 유지선(가용성 90% / 성능 80%) 예측으로 판단한다.
- 예약 계산은 bin-packing 손실·HPA 과도 구간 때문에 실제보다 낮게 나온다(실측 예측 6대 vs 실제 7대).
  `실측 평균 노드 ÷ 현재 예약 예측`을 보정 계수로 곱해 비용 이득을 낙관적으로 잡지 않는다.
- 거절된 회차의 노드 수는 같은 실행 안에서 다시 제안하지 않는다(실측으로 학습).
- 예측이 유지선(비용 우선: 가용성 90%·성능 80% / 균형: 가용성 99%·성능 30%)을 깨는 조합은
  후보에서 제외한다. 최종 채택은 항상 실측이다.
- 회차 계획은 **마지막으로 채택된 측정**을 입력으로 쓴다. 거절된 회차의 측정으로 계획하면
  이미 롤백된 상태와 어긋난 후보가 나온다(실측 사고). 롤백 후에는 settle을 기다린 뒤 다음 회차를 연다.
- **한 회차에 여러 앱을 함께 적용한다(`bundle`).** 회차당 4~5분이라 앱별로 나누면 예산이 한 앱에서
  끝난다. 상위 후보 배치에서도 한 앱이 3회를 독식하지 못하게 앱을 한 번씩 먼저 배정한다.
- Pod startup/rollout, Karpenter drain settle, HPA max, node CPU, DB/RDS·비확장성 병목을 분류해 후보와
  대기시간을 고른다. 유지선이 깨지는 후보는 절대 채택하지 않는다.
- 적용은 라이브 HPA patch + 필요할 때 Deployment request 변경이다. 총점이 오르면 채택하고, 아니면
  후보 전 snapshot으로 롤백한다. Ctrl+C/오류로 중단돼도 `finally`에서 pending 후보를 롤백한다.
- 기본 `-BudgetMinutes 18`, `-WarmupSeconds 60`, `-Duration 120s`, 후보 하드 상한 3개다.
  매 trial 전에 settle+측정+150초 롤백 여유를 예약하며 시간이 부족하면 새 후보를 시작하지 않는다.

```powershell
# 안전(기본): 1회 측정 후 '다음 한 수'만 제안 — 클러스터 불변
.\optimize.ps1

# 실제 탐색: 18분 예산, 비용 우선(가용성>=90% 성능>=80%), 여러 앱을 한 회차에 적용
.\optimize.ps1 -Apply

# 채점 부하가 측정 부하보다 가벼울 때: 목표 부하를 낮춰 사이징
.\optimize.ps1 -Apply -LoadScale 0.5
# 채점 부하량을 알 때: rps를 직접 고정 (측정 부하와 무관하게 계산)
.\optimize.ps1 -Apply -TargetRps "user=100,product=200,stress=10"
# 성능 우선(가용성 99% 유지): .\optimize.ps1 -Apply -Objective balanced
# 측정 창을 더 길게: .\optimize.ps1 -Apply -Duration 180s
```

⚠ **탐색 중과 종료 후 모두 Terraform apply는 필요 없다.** 우승값은 이미 라이브 Deployment/HPA에
적용돼 있다. 종료 출력은 기록/재현용이다. 이후 Terraform apply를 하면 라이브 우승값이 덮일 수 있으므로
공식 운영 중에는 실행하지 않는다. request가 달라지는 후보는 rollout을 포함하므로 트래픽 시작 전에만 탐색한다.

⚠ Karpenter `consolidateAfter`/`budgets`와 DB 설정은 자동 변경하지 않는다. 엔진은 노드 drain 대기와
DB/non-scalable 병목을 후보 판단에 반영하지만, 인프라·DB 변경은 별도 고위험 작업으로 남긴다.

두뇌(`optimize.py`)의 결정 로직은 `test_tuning.py`로 단위 검증한다:

```powershell
py -3 -m unittest test_tuning -v
```

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
| 트래픽 전(~3분) | `.\loadtest.ps1 -Duration 120s -Label t1` → 채점 환산 + 원인 진단 |
| 트래픽 전(~18분) | `.\optimize.ps1 -Apply` → warmup 60s + baseline 120s + 후보 최대 3개 실측 → 라이브 우승 snapshot 유지 |
| 트래픽 중 | `python waf_header_stats.py ...` → 새 패턴 차단 → `.\verify.ps1` 재확인 |
| 트래픽 중 | `.\loadtest.ps1 -Label during -Duration 90s` 로 추세 확인 (부하가 겹치니 짧게) |

> ⏱ **트래픽 전 1시간 = `terraform apply`(약 30분) + 튜닝(~20분).** 튜닝은 워밍업 후 120초 측정 + 18분
> 예산의 `optimize.ps1`로 끝낸다. 측정이 너무 짧으면 콜드스타트가 섞여 user perf 가 실제(80%+)보다 낮게 찍힌다.

**원칙**: 성능이 비용의 전제조건이다. 세 앱 중 하나라도 performance 30% 미달이면 **비용 12점이
통째로 0점**이므로, 비용을 줄이려 성능을 깎는 방향은 30% 선 근처에서 절대 금지다. 가용성은
`≥90%` 면 앱당 만점이라 대개 먼저 확보된다. 한 번에 한 앱만 바꿔야 원인 추적이 된다.

**부하 중 금지**: `requests` 변경(= `kubectl set resources`, `terraform apply` 로 파드 템플릿 변경)은
롤아웃을 일으키고 **롤아웃 자체가 504** 를 만든다. 측정·채점 트래픽이 도는 동안에는 HPA 만 만진다.
`terraform apply` 도 파드 템플릿이 바뀌면 같은 문제가 생기므로 트래픽 전에 끝낸다.

**request 를 올리기 전에 확인**: 실사용이 request 의 절반도 안 되는데 느리면 CPU 가 병목이 아니다.
그 상태에서 request 를 올리면 노드만 늘어 비용을 깎고 스케일업까지 늦어진다. `advise.py` 가
`CPU 병목 아님` 으로 판정하면 DB(RDS CPU·커넥션·쿼리지연)·CloudFront 캐시 히트율·커넥션풀
borrow 대기를 본다.

**`max_replicas` 는 성능 천장이면서 비용 천장이다.** 너무 낮으면 HPA가 필요한 평형에 도달하지
못하지만, 지속 부하에서는 높은 상한까지 실제로 파드와 노드가 늘 수 있다. 따라서 감으로 크게 열지
말고 `autotune.ps1`의 실측 공식 점수와 평균 노드 수를 함께 보고 결정한다.
