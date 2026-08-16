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
| `loadtest.ps1` | 채점 방식 부하 측정 → 리포트 + 권장값 (+ `podcpu.csv` 실사용 기록) |
| `autotune.ps1` | cpu/HPA 조합 스윕 → 최고 조합 자동 적용 |
| `score.py` | hey CSV 채점기 (`loadtest`/`autotune` 이 호출) |
| `advise.py` | 측정 + 실사용 + 라이브 상태 → **원인 구분 후** 앱별 판정 |
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
샘플링한다. 끝나면 `score.py report` 리포트와 `advise.py` 권장값이 이어서 나온다.

결과 폴더(`%TEMP%\tune-<label>`)에 남는 것:

| 파일 | 내용 | 쓰는 곳 |
|---|---|---|
| `<앱>.csv` | hey 원본 (상태코드, 응답시간) | 가용성·성능 채점 |
| `nodes.csv` | `ts,노드수,Running파드수` | 비용 지표(노드 수 평균) |
| `podcpu.csv` | `ts,파드명,cpu(밀리코어)` | **request 산정의 유일한 근거** |

`podcpu.csv` 가 필요한 이유는 request 권고가 실사용 피크에서 나오기 때문이다. 부하가 끝난 뒤
`kubectl top` 을 한 번 찍으면 그 순간값이 피크로 잡혀 과대·과소 권고가 난다. 창 전체를 남겨야
p95 를 제대로 계산할 수 있다. `metrics-server` 가 없으면 이 파일만 비고 가용성·성능 측정은 정상이다.

```
api             n  avail%  perf%     p50     p95     p99     max
user         1800  100.0%  98.2%   0.041   0.180   0.240   0.900
product      1800  100.0%  99.9%   0.012   0.030   0.050   0.210
stress        360   99.7%  95.0%   0.400   0.950   1.400   2.100
nodes      min=1 max=4 avg=2.30  (baseline=2, 비용 비율 1.15배)
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

`loadtest.ps1` 끝에서 자동 실행된다. 측정값 + 라이브 설정 + **부하 중 실사용 CPU** 를 합쳐
앱마다 판정하고, 즉시 적용 명령과 terraform 반영값을 같이 출력한다.

### request 를 다루는 원칙 (중요)

`requests.cpu` 는 **노드 예약량이지 파드 속도 상한이 아니다.** cpu limit 이 없는 앱은
request 를 올려도 빨라지지 않는다. 올리면 오히려 두 방향으로 해롭다.

- 노드당 파드 수가 줄어 **노드가 늘고 비용이 오른다**
- HPA 사용률 = 실사용 ÷ request 가 작아져 **스케일업이 늦어진다** (성능이 더 나빠질 수 있다)

그래서 "느리다 → request 올려" 는 틀린 처방이다. 원인을 먼저 가른다.

| 상황 | 판정 · 원인 | request |
|---|---|---|
| `avail < 99%` + 파드가 max 에 붙음 | 늘려 · 파드 상한 도달 | 유지, `max+2` |
| `avail < 99%` (상한 여유 있음) | 늘려 · 파드 부족/스케일 지연 | 유지, `min+1` · `util-10` |
| 느림 + 파드가 max 에 붙음 | 늘려 · 파드 상한 도달 | 유지, `max+2` |
| 느림 + 노드 CPU ≥ 80% | 늘려 · 노드 CPU 포화 | **올림** (노드 경쟁 완화. 이 경우만 유효) |
| 느림 + 실사용 < request × 0.5 | 유지 · **CPU 병목 아님** | **올리지 않음** → DB·캐시·커넥션풀 확인 |
| 느림 + 현재 사용률 < 목표 | 늘려 · 스케일 지연 | 유지, `util-15` · `min+1` |
| 느림 + 실사용이 request 에 근접 | 늘려 · 파드 CPU 포화 | 실사용 × 1.3 |
| 통과 + request ≫ 실사용 | 줄여 · 과투자 | 실사용 × 1.3 (비용↓) |
| 그 외 | 유지 · 균형 | 유지 |

권장 request 는 항상 **실사용 × 1.3** 이다. `×1.4` 같은 임의 배수를 쓰지 않는다.

### 실사용을 무엇으로 재는가

출력 첫 줄의 `실사용 근거` 를 반드시 확인한다.

| 표시 | 의미 |
|---|---|
| `부하 창 p95 (podcpu.csv)` | 정상. 부하 중 5초 간격 표본의 **순위기반 p95** |
| `지금 순간값 1회 [!] 근거 약함` | `podcpu.csv` 가 없어 폴백. **이 회차의 request 권고는 신뢰하지 말 것** |

순간값 하나로 판단하면 찍히는 타이밍이 값을 정해버린다. 실제로 겪은 사고다.

```
실사용 132m 지속 + 230m 스파이크 1회
순간값 230m  ->  request 300m 권고   (과대)
부하 창 p95 132m  ->  request 175m   (정상)
```

p95 는 **보간 없는 순위 기반**으로 계산한다. `statistics.quantiles` 같은 보간형은 표본이 적을 때
상위 백분위가 최댓값으로 끌려간다(실측: 120~152m 표본 19개 + 400m 1개에서 p95 가 388m).
5초 간격 180초면 표본이 36개뿐이라 이 차이가 그대로 권고값을 흔든다.

### 대회날 변경 대응

앱 이름·개수·SLO·노드 타입을 코드에 박지 않는다.

- **앱 목록**: 결과 폴더의 `<앱>.csv` 에서 자동 발견
- **SLO**: `--slos user=0.2,product=0.2,stress=1.0`. 목록에 없는 앱은 `--default-slo`(기본 1.0초)를
  쓰고 `[!] SLO 미지정 앱` 경고를 낸다 → 문제지 값으로 `--slos` 를 지정할 것
- **노드 할당가능 CPU**: 라이브 `status.allocatable` 에서 읽는다. 여러 타입이 섞이면 가장 작은 노드
  기준(노드 수 과소추정 방지). 못 읽으면 `미확인(추정 생략)` 으로 두고 틀린 숫자를 내지 않는다

```powershell
python advise.py <label|폴더> [--slos user=0.2,...] [--default-slo 1.0] [--ns app]
```

### 적용

`kubectl set resources` / `patch hpa` 는 **임시**다(apply 하면 사라짐). 확정된 값은
`terraform/k8s_apps.tf` 의 `requests.cpu` / HPA `average_utilization`·`min_replicas`·`max_replicas`
에 박고 `terraform apply`.

⚠ **부하 측정 중에는 `requests` 를 바꾸지 않는다.** requests 변경은 파드 롤아웃을 일으키고,
롤아웃 자체가 504 를 만들어 가용성 점수를 깎는다. 측정 중에 손대야 하면 **HPA 만** 만진다.
advise.py 도 request 가 안 바뀌면 `set resources`·`rollout status` 를 아예 출력하지 않는다.

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

**부하 중 금지**: `requests` 변경(= `kubectl set resources`, `terraform apply` 로 파드 템플릿 변경)은
롤아웃을 일으키고 **롤아웃 자체가 504** 를 만든다. 측정·채점 트래픽이 도는 동안에는 HPA 만 만진다.
`terraform apply` 도 파드 템플릿이 바뀌면 같은 문제가 생기므로 트래픽 전에 끝낸다.

**request 를 올리기 전에 확인**: 실사용이 request 의 절반도 안 되는데 느리면 CPU 가 병목이 아니다.
그 상태에서 request 를 올리면 노드만 늘어 비용을 깎고 스케일업까지 늦어진다. `advise.py` 가
`CPU 병목 아님` 으로 판정하면 DB(RDS CPU·커넥션·쿼리지연)·CloudFront 캐시 히트율·커넥션풀
borrow 대기를 본다.
