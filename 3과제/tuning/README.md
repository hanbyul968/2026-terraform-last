# tuning/ — 부하 테스트 & 자동 튜닝 (Windows PowerShell 기준)

대회 채점 방식(가용성 / 성능효율 / 비용)과 동일하게 부하를 걸고, HPA·request 값을
**자동으로 스윕해 최적값을 찾는** 도구 모음. **Windows PowerShell**에서 바로 돌아간다.

> ⚠️ 절대값(예: `cpu 500m`)은 **앱마다 다르다**. 대회날 새 앱을 받으면 `config.ps1`만
> 고쳐 `autotune.ps1`로 그 자리에서 최적값을 다시 찾는 게 이 도구의 목적이다.
> terraform 의 기본값은 "앱 안 타는 견고한 출발점"일 뿐, 정답이 아니다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `config.ps1`    | **대회날 여기만 수정** — `$ENDPOINT`(한 번만) + API 목록·SLO·부하파라미터·시드 |
| `setup.ps1`     | 부트스트랩 (hey.exe·kubectl.exe 설치 + kubeconfig) |
| `loadtest.ps1`  | 1회 부하 + 채점식 측정 (가용성/perf/노드수) + **끝에 advise.py 자동 호출** |
| `advise.py`     | **측정 → 앱별 늘려/줄여/유지 판정 + 복붙 명령**(kubectl/terraform) 출력 |
| `autotune.ps1`  | 조합 그리드 자동 스윕 → 채점 → 우승자 적용 (`-App <앱>` 앱별 정밀) |
| `autotune-hc.ps1`| 힐클라이밍 정밀탐색 (노드 드레인으로 노이즈↓) |
| `score.py`      | hey CSV 채점기 (위 스크립트들이 공용으로 호출) |
| `waf_header_stats.py`| WAF 로그 분석 + terraform.tfvars 제안 (boto3, 크로스플랫폼) |

---

## PowerShell 빠른 시작

전제: **`aws` CLI + `python`(+`boto3`) 설치**, 그리고 `aws configure`로 **리소스가 떠 있는
그 계정**의 자격증명이 잡혀 있어야 한다(CloudShell 처럼 ambient 아님).

```powershell
# 0) 도구 받기 (이미 클론돼 있으면 생략)
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform\3과제\tuning

# (실행 정책 때문에 스크립트가 막히면 이 세션만 허용)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 1) 부트스트랩 — hey.exe/kubectl.exe 설치(%USERPROFILE%\bin) + kubeconfig
.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2

# 2) 클러스터 보이는지 확인
kubectl -n app get pods

# 3) 엔드포인트를 config.ps1 에 한 번만 붙여넣기 (terraform output 또는 CloudFront 콘솔)
#    config.ps1 상단:  $ENDPOINT = 'http://dxxxx.cloudfront.net'
#    → 이후 모든 스크립트가 이 값을 쓴다 (매번 주소 안 쳐도 됨).

# 4) baseline 측정  →  5) 최적값 자동 탐색  (엔드포인트 생략!)
.\loadtest.ps1 180s baseline
.\autotune.ps1 -App stress
```
> 특정 실행만 다른 엔드포인트로 하려면 `-Url http://...` 를 붙이면 그 값이 우선한다.

### hey 설치 실패 시 (loadtest가 전부 `NO DATA`)
`setup.ps1`은 hey.exe 를 공식 S3 미러에서 받는데, 미러가 **403(AccessDenied)** 를 내면
깨진 파일이 저장돼 실행이 안 되고 측정이 `NO DATA`로 나온다. 확인·복구:

```powershell
# 진단: 정상이면 usage, 깨졌으면 에러/빈 출력
hey -h
Get-Item "$env:USERPROFILE\bin\hey.exe" | Select-Object Length   # 수 MB 면 정상, 수백 B 면 깨짐

# 복구 1) 다시 받기
Invoke-WebRequest 'https://hey-release.s3.us-east-2.amazonaws.com/hey_windows_amd64' `
  -OutFile "$env:USERPROFILE\bin\hey.exe"

# 복구 2) Go 로 직접 빌드 (Go 설치돼 있으면)
$env:GOBIN = "$env:USERPROFILE\bin"; go install github.com/rakyll/hey@latest
```

> `setup.ps1`은 `%USERPROFILE%\bin` 에 설치하고 사용자 PATH 에 등록한다(새 창부터 자동 적용).
> 결과 CSV 는 `%TEMP%\tune-<label>\` 에 쌓인다.

---

## config.ps1 — 대회날 채우는 곳

```powershell
$APIS = @(
  # name / slo(초) / conc / qps / method / path(쿼리포함) / body(POST만, GET은 $null)
  @{ name='user';    slo=0.2; conc=30; qps=10; method='GET';  path="/v1/user?email=loadseed1@example.org&..."; body=$null }
  @{ name='product'; slo=0.2; conc=30; qps=10; method='GET';  path="/v1/product?id=loadseedp1&...";            body=$null }
  @{ name='stress';  slo=1.0; conc=12; qps=2;  method='POST'; path='/v1/stress'; body=(@{requestid='1';uuid=$UUID;length=64}|ConvertTo-Json -Compress) }
)
$SEEDS = @(  # GET 부하가 맞힐 행 미리 삽입
  @{ method='POST'; path='/v1/user';    body=(@{requestid='1';uuid=$UUID;username='loadseed1';email='loadseed1@example.org'}|ConvertTo-Json -Compress) }
  @{ method='POST'; path='/v1/product'; body=(@{requestid='1';uuid=$UUID;id='loadseedp1';name='loadseedp1';price=1}|ConvertTo-Json -Compress) }
)
$AVAIL_GATE   = 99     # 가용성 합격선(%); 미만이면 autotune 점수 실격
$COST_PENALTY = 6      # 노드 평균 1대 초과당 감점
$NS           = 'app'  # k8s 네임스페이스
```
- `name`은 **같은 이름의 Deployment**를 autotune이 튜닝한다(앱 이름 = Deployment 이름 전제).
- `slo`는 채점기준표의 성능 기준(초)을 그대로 넣는다.

---

## loadtest.ps1

```powershell
.\loadtest.ps1 [duration] [label] [-Url http://...]   # 엔드포인트는 config.ps1 $ENDPOINT
```
config의 모든 API에 동시에 부하 → 출력:

```
=== baseline ===
api             n  avail%  perf%     p50     p95     p99     max
user         5400  100.0%  99.6%   0.041   0.058   0.071   0.210
product      5400  100.0%  99.7%   0.039   0.056   0.069   0.198
stress        720  100.0%  81.6%   0.630   0.940   0.980   1.120
nodes      min=2 max=6 avg=3.40  (cost proxy avg/2 = 1.70)
```
- `perf%`↑ = 성능점수↑, `nodes avg`↓ = 비용점수↑ (트레이드오프).
- 산출물: `%TEMP%\tune-<label>\{<api>.csv, nodes.csv}`.

## advise.py — "딱 정해주는" 권장값 + 복붙 명령

`loadtest.ps1` 이 **끝에서 자동 호출**한다. 측정(perf/avail/p95)과 라이브 클러스터 상태
(cpu request·HPA util/min·현재 CPU%)를 합쳐 **앱마다 [늘려/줄여/유지]를 판정**하고,
그대로 칠 수 있는 명령을 뽑아준다. 따로 돌리려면:

```powershell
python advise.py <label>            # 예: python advise.py baseline
python advise.py <결과폴더경로>      # %TEMP%\tune-<label> 이 아닌 경우
```

출력 예:

```
[stress]  판정: 늘려 ↑   (perf 90.0% / p95 1.810s > SLO 1.0s (꼬리지연))
  현재: cpu=500m util=55% min=2 max=10 파드=2
  권장: cpu=700m util=45% min=2 max=10
  즉시 적용 (임시 - 재배포 시 사라짐):
    kubectl -n app set resources deploy/stress --requests=cpu=700m
    kubectl -n app patch hpa stress --type=merge -p '{...}'
    kubectl -n app rollout status deploy/stress
...
  영구 반영 → terraform/k8s_apps.tf 해당 앱 수정 후:
  stress  : requests.cpu = "700m"   average_utilization = 45   min_replicas = 2
```

**판정 우선순위 (채점 순서와 동일)**
1. `avail < 99%` → **늘려**(게이트 최우선): cpu×1.5, min+1, util−5 — 비용보다 먼저
2. `perf < 95%` 또는 `p95 > SLO` → **늘려**(꼬리지연): cpu×1.4, util−10
3. `perf ≥ 99.5%` + 현재CPU ≪ 목표 → **줄여**(과투자→비용↓): cpu×0.75, util+10, min−1
4. 그 외 → **유지**

> 즉시 적용(kubectl)은 **임시** — 좋으면 반드시 `k8s_apps.tf` 에 박아 apply(아래). 한 번에 한 앱만.

## autotune.ps1 — 그리드 자동 스윕

```powershell
.\autotune.ps1 [-Duration 90s]      # 모든 앱 균일 (방향 탐색)
.\autotune.ps1 -App stress          # 그 앱만 튜닝 (앱별 정밀) ★권장
```
> 엔드포인트는 config.ps1 의 `$ENDPOINT`. 다른 주소면 `-Url http://...` 추가.
- **기본 모드**: config의 모든 앱에 **균일한 (cpu·util·min·max)** 조합을 차례로 적용(live `kubectl patch`, terraform 재apply 없음). 대략적인 방향 탐색용.
- **`-App <앱>` 모드**: **그 앱만** patch 하고 나머지는 현재 설정 유지. 점수도 그 앱의 perf 기준
  (가용성 게이트는 여전히 전체 앱 최소값 — 다른 앱을 죽이는 조합은 탈락).
  → **loadtest 로 병목 앱을 찾고 → 그 앱만 `-App` 으로 도는 것**이 낭비 없는 워크플로.
- 조합당: patch → rollout → 45s 안정화 → loadtest → 채점.
- 점수 = `perf% − 노드비용패널티 − (가용성<GATE면 실격)`.
- 끝나면 **우승 조합을 클러스터에 적용**하고 terraform 반영값을 출력.
- 조합은 스크립트 상단 `$COMBOS`에서 추가/수정.

## autotune-hc.ps1 — 힐클라이밍 정밀탐색

```powershell
.\autotune-hc.ps1 [duration] [start_cpu] [start_util] [max_moves] [-Url http://...]
```
- 시작점에서 cpu(±100m)·util(±5)을 흔들어 점수 개선 방향으로 이동(first-improvement).
- 매 trial 전 **노드를 baseline까지 드레인**(Karpenter consolidation 대기) → 비용 측정 노이즈↓.
- `autotune.ps1`로 대략 우승 영역 찾은 뒤, 그 근처를 정밀화할 때 사용.

---

## 대회날 워크플로 (요약)

1. **PowerShell** 열기 → `git clone` → `cd tuning` (자격증명은 미리 `aws configure`).
2. `.\setup.ps1 -Cluster <cluster> -Region <region>`.
3. 받은 앱·채점기준표 보고 **`config.ps1`의 $APIS/$SEEDS/SLO 수정**.
4. `.\loadtest.ps1 180s baseline`로 현재 상태 확인 (엔드포인트는 config.ps1 $ENDPOINT).
5. `.\autotune.ps1 -App <병목앱>`로 최적 조합 선정 → 필요하면 `autotune-hc.ps1`로 정밀화.
6. 출력된 값으로 `terraform/k8s_apps.tf` 수정 후 `terraform apply` (영구 반영).

> 부하는 Karpenter 노드를 띄워 **비용 발생**. 끝나면 consolidation(~30s) 확인,
> 종료 시 `terraform destroy`.

---

## 결과 쉽게 읽는 법 (초보용)

`loadtest.ps1` / `autotune.ps1` 출력을 한 줄씩 풀면:

```
api      n      avail%  perf%   p50    p95    p99    max
stress   2686   100.0%  71.7%   0.594  1.907  2.274  2.974
```

| 항목 | 뜻 | 쉽게 |
|---|---|---|
| `n`       | 보낸 요청 수 | 클수록 통계 믿을만 |
| `avail%`  | 5초 안에 성공(2xx)한 비율 | **가용성 점수**. 99% 밑이면 큰일(요청 실패/지연) |
| `perf%`   | **SLO 시간 안**에 답한 비율 | **성능 점수**. 높을수록 좋음 |
| `p50`     | 절반이 이 시간 안에 응답 | 보통 빠름 |
| `p95/p99` | 상위 5%/1% 느린 요청 시간 | **여기가 SLO 넘으면 perf% 깎임 (꼬리지연)** |
| `max`     | 가장 느린 1건 | 참고용 |
| `nodes avg` | 테스트 중 평균 노드 수 | **비용**. 낮을수록 비용 점수↑ |

**핵심 직관 3가지**
1. `perf%`가 낮은 API = **느린 API**. 거기만 고치면 됨 (다른 API 건들 필요 X).
2. `p50`은 통과인데 `p95/p99`가 SLO 초과 = **꼬리지연** = 부하 몰릴 때 CPU 부족/스케일이 느린 것.
3. `avail%`가 99% 밑 = **용량 자체가 부족**(요청이 5초 넘거나 에러). 비용보다 무조건 먼저 해결.

> 위 예시: user/product는 perf 100%(완벽), **stress만 71.7%**라 stress가 병목. p50 0.6초는 통과인데 p95 1.9초가 SLO(1.0초)를 넘어서 점수가 깎임 → "부하 시 stress가 CPU에 막힌다"는 신호.

---

## 해석값 → 어떤 설정을 바꿀까

> **판정·명령은 `advise.py`가 자동으로 준다** (loadtest 끝에 자동 실행, 또는 `python advise.py <label>`).
> 아래는 그 판정 뒤에 있는 원리 — advise 결과를 이해·검증할 때만 보면 된다.

| 증상 | 원인 | 손잡이 (전부 `k8s_apps.tf`의 각 앱) |
|---|---|---|
| **avail% < 99%** | 용량 부족 (실패/5초 초과) | `min_replicas`↑, `requests.cpu`↑ — **비용보다 최우선(게이트)** |
| **perf% 낮음 + p95 ≫ SLO** | CPU 부족 / 스케일 느림 | `requests.cpu`↑ / HPA `averageUtilization`↓ / `min_replicas`↑ |
| **perf 100%인데 nodes 많음** | 과투자(비용 낭비) | `requests.cpu`↓ / `averageUtilization`↑ |
| **특정 앱만 나쁨** | 그 앱만 무거움 | **그 앱만** 키운다 (모든 앱 똑같이 X) |

**손잡이 3개, 방향만 기억** (advise.py가 이 방향으로 값을 계산):
- `requests.cpu` ↑ → 파드 1개가 더 셈(꼬리지연↓) / 노드 더 필요(비용↑)
- `average_utilization` ↓ → 더 빨리·자주 스케일(성능↑/비용↑), ↑ → 느긋(비용↓)
- `min_replicas` ↑ → 부하 초반부터 여유(avail↑)

**적용**: advise가 출력한 `kubectl` 명령으로 즉시 실험(임시) → 좋으면 같은 값을 `k8s_apps.tf`의
**그 앱만** 수정하고 `cd ..\terraform ; terraform apply -auto-approve -var "k8s_provider_ready=true"` (영구).
한 번에 한 앱만 바꾸고 loadtest로 재측정.

### 노드가 너무 쉽게 늘어날 때 (비용 ratio↑)

노드 증가의 진짜 원인은 대개 **HPA가 파드를 과도하게 늘리는 것**이다(파드↑ → 노드↑).
`k8s_apps.tf` 의 HPA 는 이미 **덜 과민하게** 조정돼 있다(기본값):

| 손잡이 | 값 | 효과 |
|---|---|---|
| `average_utilization` | **60** (과거 55) | CPU 더 차야 확장 → 파드·노드 덜 늘어남 |
| `scale_up.stabilization_window_seconds` | **30** (과거 0) | 순간 스파이크 무시, 지속될 때만 확장 |
| `scale_up` policy | **+50% / +2 pods** per 15s (과거 100%/4) | 한 번에 폭증 안 함 |
| Karpenter `consolidateAfter` (`karpenter.tf`) | **30s** (과거 60) | 부하 빠지면 빨리 노드 회수 |

**그래도 노드가 많으면** (advise.py 가 「줄여 ↓」 로 판정하는 앱):
1. 과투자 앱의 `requests.cpu`↓ → 노드당 파드 밀도↑ → 노드 수↓ (가장 효과적)
2. 그 앱 HPA `average_utilization`↑ (60 → 70) → 더 느긋하게 확장
3. `min_replicas` 가 3+ 면 2로 → 유휴 파드 감소

> ⚠️ 단 **avail% 99% 는 절대 사수**. 노드를 줄이려다 가용성 깨지면 12점이 날아간다.
> `requests.cpu` 를 실사용량보다 너무 낮추면 부하 시 파드가 터지니, advise.py 권장값(실측 기반)을 따를 것.

### autotune 우승값을 그대로 쓰면 안 되는 이유 (기본 모드)
기본 모드는 **모든 앱에 똑같은 cpu/util**을 적용해 비교한다. 그래서 우승값(예: `300m 균일`)을
그대로 박으면:
- user/product엔 **과함** → 노드 늘어 비용↑
- stress엔 **부족** → 성능 그대로

→ 해결책은 **`-App` 모드**: 병목 앱만 골라 `.\autotune.ps1 -App stress` 로 돌리면
그 앱만 patch/채점하므로 우승값을 **그 앱에 그대로 반영**해도 된다.
예) user/product `cpu=200m` 유지, stress 만 `-App` 으로 `750~900m` 탐색.

### 점수 읽을 때 주의
- `autotune`은 보통 **90초** 런이라 노이즈가 크다. 1~2점 차이는 **동률**로 본다.
- 점수 = `평균 perf% − (노드평균−2)×비용패널티 − (가용성<게이트면 −50)`.
  → 가용성 게이트(`AVAIL_GATE`, 기본 99%)를 못 넘기면 아무리 싸도 −50으로 탈락.
- `kubectl patch`(autotune/advise)는 **임시** — 재배포 시 사라진다. 영구 반영은 위 "적용" 참고.

---
## WAF 차단 분석 — `waf_header_stats.py`

대회 트래픽의 **공격(비정상) 요청**이 WAF에서 막히고 있는지, **아직 안 막힌 게 뭔지**를
WAF 로그로 뽑아주는 도구. (WAF는 CloudFront scope → **로그는 us-east-1**)

```powershell
pip install boto3        # 최초 1회
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```
- 로그그룹 = `aws-waf-logs-<project>` (기본 `project=wsi2026`).
- ⚠ **`--hours 1`** 로 볼 것 — 길게 잡으면 룰 적용 *전* 옛 기록이 섞여 "안 막혔다"로 오해.
- 경로가 바뀐 날은 `--api-paths "/v2/user,/v1/product,..."` 로 유효 경로를 맞춰줘야 404 판정이 정확.

출력 맨 위 **「아직 안 막힌 비정상/의심 요청」** + 그 아래 **「제안」 섹션**(terraform.tfvars 값)을 본다.
제안이 있으면 그 값을 tfvars에 넣고 apply → 다시 돌려 그 칸이 빌 때까지 반복.

> **막는 법·판정 읽는 법·적용/검증의 전체 절차는 [`../terraform/README.md`](../terraform/README.md)의
> "WAF 운영 — 안전 기본값 + 관찰 추가" 섹션**에 있다 (여기 중복 두지 않음).
> 요지: 유효 경로(`/v1/*`)의 비정상 = **403 차단 대상**, 없는 경로(`/.env` 등) = **404가 정답**(막지 않음).
> `tools/dashboard.py` 「WAF분석」 탭에 위 출력을 붙여넣으면 같은 tfvars 값을 GUI로도 준다.
