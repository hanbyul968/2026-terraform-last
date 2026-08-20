# tuning/ — 부하 측정 · 응답규약 검증 · 비파괴 권장값 계산

3과제 40점은 **전부 부하 테스트 결과**로 매겨진다. 이 폴더는 채점과 같은 방식으로 미리 재보고,
어디를 고칠지 정해주는 도구 모음이다. Windows PowerShell 기준.

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
| `optimize.ps1` | **닫힌 루프 최적화** — 측정→채점→HPA 패치→재측정을 반복해 공식 총점이 최대가 되는 HPA 값을 탐색 (`-Apply` 없으면 제안만) |
| `optimize.py` | optimize.ps1 의 두뇌. `score.py` 총점을 목적함수로 '다음 한 수'를 고름(순수 함수, 단위테스트) |
| `score.py` | hey CSV 채점기 (`loadtest`/`autotune`/`optimize` 가 호출). `score` 모드는 총점 JSON 출력 |
| `advise.py` | 측정 + 실사용 + 라이브 상태 → **원인 구분 후** 앱별 판정 (양방향: 비용 여유 시 target ↑ 권고) |
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
.\autotune.ps1 -Result baseline                         # 3) request+HPA 권장값만 계산(변경 없음)
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
.\loadtest.ps1 -Duration 180s -Label baseline
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

## advise.py — 비파괴 request/HPA 계산

`loadtest.ps1` 끝에서 자동 실행된다. 측정 결과, 활성 부하창의 Pod/노드 CPU, 라이브
Deployment/HPA 설정을 읽어서 앱별 `requests.cpu`, `min`, `max`, `target%` 권장값을 출력한다.
클러스터나 Terraform은 변경하지 않는다.

핵심 공식:

```text
현재 파드당 목표 CPU = requests.cpu × target / 100
필요 replica ≈ ceil(활성창 총 CPU p90 / 권장 파드당 목표 CPU)
```

request는 CPU 제한이 아니라 예약량이므로 성능이 낮다는 이유만으로 올리지 않는다. 활성 부하창에서
노드 CPU가 90% 이상이고 파드 CPU p90이 현재 request보다 10% 이상 높을 때만, 한 회차 최대 25%씩
올린다. request가 바뀌면 기존 HPA 민감도를 유지하도록 target을 역산한 뒤, 30% 성능 게이트 또는
가용성 미달일 때만 파드당 목표 CPU를 5~10% 추가로 낮춘다.

**양방향(비용 회수).** 노드가 기준을 초과하고(ratio>1) 성능이 최상위 밴드(≥90%)로 안전하며 파드가
request 대비 저활용(<60%)이면 target을 한 스텝(+10%p, 상한 85) 올려 파드/노드를 줄이도록 권고한다.
기존에는 성능 보호로 target을 내리기만 해 노드가 남아돌아도 비용을 못 줄였다. 단, "어디까지 올릴 수
있나"의 정밀 탐색은 단일 회차 측정만으로는 알 수 없으므로 `optimize.ps1`(닫힌 루프)이 담당한다.

`podcpu.csv`와 `nodecpu.csv`는 반드시 `loadwindows.csv`의 start/end 안에 있는 표본만 사용한다.
이 필터가 UTC+9가 중복 적용된 표본과 부하 종료 후 유휴 표본을 제거한다. 백분위는 표본 수가 적어도
최댓값 보간에 끌려가지 않도록 nearest-rank 방식으로 계산한다.

```powershell
py -3 .\advise.py baseline --slos user=0.2,product=0.2,stress=1.0 --ns app
py -3 .\advise.py baseline --slos user=0.2,product=0.2,stress=1.0 --ns app --app user
```

출력은 다음 측정 회차를 위한 1-step 권장값이다. 사용자가 `k8s_apps.tf`에 직접 반영하고 apply한 뒤
새 label로 180초 재측정한다. 부하 중 request 변경은 롤아웃을 일으키므로 공식 트래픽 전 작업한다.

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
.\loadtest.ps1 -Duration 180s -Label baseline

# 전체 앱 권장값만 출력
.\autotune.ps1 -Result baseline

# 한 앱만 출력
.\autotune.ps1 -Result baseline -App user
```

이 스크립트와 `advise.py`는 `kubectl patch`, `kubectl set resources`, rollout 또는
`terraform apply`를 실행하지 않는다. 출력된 값을 사용자가 검토한 뒤
`terraform/k8s_apps.tf`에 직접 반영하고 새 label로 재측정한다.

계산 원칙:

1. `loadwindows.csv`의 실제 활성 부하창에 해당하는 `podcpu.csv`/`nodecpu.csv` 표본만 사용한다.
   UTC+9 오염 표본과 부하 종료 후 유휴 표본은 버린다.
2. HPA의 실질 기준은 `requests.cpu × target%`인 파드당 목표 CPU다.
3. 노드 CPU가 90% 이상이고 파드 CPU p90이 request를 10% 이상 넘을 때만 request를 올린다.
   한 회차 조정폭은 최대 25%다.
4. request가 바뀌면 기존 HPA 민감도를 보존하도록 target을 역산한다. 성능 30% 게이트나
   가용성이 미달일 때만 파드당 목표 CPU를 추가로 5~10% 낮춘다.
5. 활성창 총 CPU p90을 권장 파드당 목표 CPU로 나눠 필요 replica를 계산한다.
   `minReplicas`는 항상 2로 고정해 유휴 시 관리형 2노드로 복귀하게 하고, 성능 여유는 target과 max로 확보한다.
6. 세 앱 중 하나라도 성능 30% 미만이면 비용 12점이 전부 0이므로 30% 게이트 복구가 우선이다.

권장값은 영구 정답이 아니라 **다음 측정 회차용 1-step 값**이다. 한 번 반영한 뒤 반드시
다른 label로 180초 재측정하고 다시 계산한다. 앱·트래픽·바이너리가 바뀌면 이전 결과를 재사용하지 않는다.

## optimize.ps1 — 닫힌 루프 최적화 (공식 총점 최대화)

`advise.py`/`autotune.ps1`은 한 회차 측정으로 "1-step 권고"만 낸다. 그런데 **최적 HPA target은
한 번 측정으로는 알 수 없다** — target을 올리면 파드가 줄어 지연이 얼마나 늘지(성능%가 어느 밴드로
떨어질지)는 그 지점을 실제로 측정해야만 안다. `optimize.ps1`은 이걸 **측정→채점→조정→재측정**의
닫힌 루프로 푼다.

- 목적함수 = `score.py`의 **공식 채점 총점**(성능+가용성+비용, 36점). 근사식이 아니다.
- 좌표상승법으로 한 회차에 **한 수**만 둔다: 게이트 위반 복구 > 성능 밴드 경계 넘기기(target↓) >
  비용 회수(ratio>1 & 성능 여유 → target↑). 개선 후보가 없으면 수렴 선언.
- HPA만 `kubectl patch`(즉시·되돌림 가능, terraform state 불변)로 바꿔 빠르게 탐색한다.
  총점이 오르면 채택, 아니면 되돌리고 그 수는 재제안 금지한다. 예측이 틀려도 실측이 교정한다.

```powershell
# 안전(기본): 1회 측정 후 '다음 한 수'만 제안 — 클러스터 불변
.\optimize.ps1

# 실제 탐색: HPA를 패치하며 공식 총점이 최대가 되는 값을 찾는다
.\optimize.ps1 -Apply -Iterations 8 -Duration 90s -FinalDuration 180s
```

⚠ **탐색 중에는 `terraform apply` 금지** — kubectl 패치가 되돌려진다. 루프가 끝나면 우승 HPA 값을
Terraform 형식으로 출력하므로, 그 값을 `k8s_apps.tf`에 반영하고 apply해 영구화한 뒤 한 번 더
`loadtest.ps1`로 확정한다.

⚠ `optimize.ps1`은 **HPA(target/min/max)만** 탐색한다. Karpenter `consolidateAfter`/`budgets`
같은 노드 회수 노브는 HPA가 아니라 건드리지 않으므로, 비용을 더 줄여야 하면 `karpenter.tf`에서
따로 조정한다.

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
| 트래픽 전 | `.\loadtest.ps1 -Duration 180s -Label t1` → 채점 환산 + 원인 진단 |
| 트래픽 전 | `advise.py` 권고를 `k8s_apps.tf` 에 반영 → apply → `-Label t2` 재측정 (2~3회 반복) |
| 트래픽 전 | (선택) `.\optimize.ps1 -Apply` — 공식 총점을 목적함수로 HPA를 자동 탐색·최적화 후 우승값 반영 |
| 트래픽 중 | `python waf_header_stats.py ...` → 새 패턴 차단 → `.\verify.ps1` 재확인 |
| 트래픽 중 | `.\loadtest.ps1 -Label during` 로 추세 확인 (부하가 겹치니 짧게) |

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
