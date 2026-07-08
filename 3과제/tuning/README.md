# tuning/ — 부하 테스트 & 자동 튜닝 (Windows PowerShell 기준)

대회 채점 방식(가용성 / 성능효율 / 비용)과 동일하게 부하를 걸고, HPA·request 값을
**자동으로 스윕해 최적값을 찾는** 도구 모음. **Windows PowerShell**에서 바로 돌아간다.

> ⚠️ 절대값(예: `cpu 500m`)은 **앱마다 다르다**. 대회날 새 앱을 받으면 `config.ps1`만
> 고쳐 `autotune.ps1`로 그 자리에서 최적값을 다시 찾는 게 이 도구의 목적이다.
> terraform 의 기본값은 "앱 안 타는 견고한 출발점"일 뿐, 정답이 아니다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `config.ps1`    | **대회날 여기만 수정** — 엔드포인트 API 목록·SLO·부하파라미터·시드 |
| `setup.ps1`     | 부트스트랩 (hey.exe·kubectl.exe 설치 + kubeconfig) |
| `loadtest.ps1`  | 1회 부하 + 채점식 측정 (가용성/perf/노드수) |
| `autotune.ps1`  | 조합 그리드 자동 스윕 → 채점 → 우승자 적용 |
| `autotune-hc.ps1`| 힐클라이밍 정밀탐색 (노드 드레인으로 노이즈↓) |
| `score.py`      | hey CSV 채점기 (위 스크립트들이 공용으로 호출) |
| `waf_header_stats.py`| WAF 로그 분석 (boto3, 크로스플랫폼) |

> 기존 `*.sh`(CloudShell/bash 판)도 참조용으로 남아 있지만, Windows 에서는 위 `*.ps1` 을 쓴다.

---

## PowerShell 빠른 시작

전제: **`aws` CLI + `python`(+`boto3`) 설치**, 그리고 `aws configure`로 **리소스가 떠 있는
그 계정**의 자격증명이 잡혀 있어야 한다(CloudShell 처럼 ambient 아님).

```powershell
# 0) 도구 받기 (이 레포의 tuning 폴더)
git clone https://github.com/gmst-cc/wsi-2026-task3.git
cd wsi-2026-task3\tuning

# (실행 정책 때문에 스크립트가 막히면 이 세션만 허용)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 1) 부트스트랩 — hey.exe/kubectl.exe 설치(%USERPROFILE%\bin) + kubeconfig
.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2

# 2) 클러스터 보이는지 확인
kubectl -n app get pods

# 3) 엔드포인트 확인 (terraform output 또는 CloudFront 콘솔)
#    예: http://dj1k92w9552mb.cloudfront.net

# 4) baseline 측정
.\loadtest.ps1 http://<endpoint> 180s baseline

# 5) 최적값 자동 탐색
.\autotune.ps1 http://<endpoint> 90s
```

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
.\loadtest.ps1 <endpoint> [duration] [label]
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

## autotune.ps1 — 그리드 자동 스윕

```powershell
.\autotune.ps1 <endpoint> [-Duration 90s]            # 모든 앱 균일 (방향 탐색)
.\autotune.ps1 <endpoint> -App stress                # 그 앱만 튜닝 (앱별 정밀) ★권장
```
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
.\autotune-hc.ps1 <endpoint> [duration] [start_cpu] [start_util] [max_moves]
```
- 시작점에서 cpu(±100m)·util(±5)을 흔들어 점수 개선 방향으로 이동(first-improvement).
- 매 trial 전 **노드를 baseline까지 드레인**(Karpenter consolidation 대기) → 비용 측정 노이즈↓.
- `autotune.ps1`로 대략 우승 영역 찾은 뒤, 그 근처를 정밀화할 때 사용.

---

## 대회날 워크플로 (요약)

1. **PowerShell** 열기 → `git clone` → `cd tuning` (자격증명은 미리 `aws configure`).
2. `.\setup.ps1 -Cluster <cluster> -Region <region>`.
3. 받은 앱·채점기준표 보고 **`config.ps1`의 $APIS/$SEEDS/SLO 수정**.
4. `.\loadtest.ps1 <ep> 180s baseline`로 현재 상태 확인.
5. `.\autotune.ps1 <ep> 90s`로 최적 조합 선정 → 필요하면 `autotune-hc.ps1`로 정밀화.
6. 출력된 값으로 `terraform/k8s_apps.tf` 수정 후 `terraform apply` (영구 반영).

> 부하는 Karpenter 노드를 띄워 **비용 발생**. 끝나면 consolidation(~60s) 확인,
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

## 해석값 → 어떤 설정을 바꿀까 (처방표)

| 증상 (무엇을 보나) | 원인 | 바꿀 설정 (`terraform/k8s_apps.tf`) |
|---|---|---|
| **avail% < 99%** | 용량 부족 (요청 실패/5초 초과) | `min_replicas`↑, `requests.cpu`↑ — **비용보다 최우선** (채점 게이트) |
| **perf% 낮음 + p95 ≫ SLO** | 그 앱 CPU 부족 / 스케일이 느림 | 그 앱 `requests.cpu`↑ / HPA `averageUtilization`↓(빨리 스케일아웃) / `min_replicas`↑ |
| **perf 100%인데 nodes 많음** | 과투자(비용 낭비) | `requests.cpu`↓ / `averageUtilization`↑ / `max_replicas`↓ |
| **특정 앱만 나쁨** | 그 앱만 무거움 | **그 앱만** 키운다 (모든 앱 똑같이 X) |

### 어떻게 바꾸나 (구체적 방법)

바꿀 손잡이는 딱 3개, 전부 `terraform/k8s_apps.tf`의 **각 앱**에 있다.

```hcl
# (1) CPU 요청량 — kubernetes_deployment.<app> 의 container 안
resources {
  requests = { cpu = "900m", memory = "128Mi" }   # ← 이 cpu 숫자
  limits   = { memory = "512Mi" }
}

# (2) HPA — kubernetes_horizontal_pod_autoscaler_v2.<app> 안
spec {
  min_replicas = 3      # ← 시작 파드 수 (천장/바닥)
  max_replicas = 10     # ← 최대 파드 수
  metric {
    resource {
      name = "cpu"
      target { type = "Utilization", average_utilization = 55 }  # ← 이 숫자 낮출수록 빨리 스케일아웃
    }
  }
}
```

**손잡이별 효과 (한 방향만 기억)**
- `requests.cpu` ↑ → 파드 1개가 더 세짐(꼬리지연↓) / 단 노드 더 필요(비용↑)
- `average_utilization` ↓ → 더 **빨리·자주** 파드 늘림(성능↑/비용↑), ↑ → 느긋(비용↓)
- `min_replicas` ↑ → 부하 초반부터 여유(avail↑) / `max_replicas` ↑ → 폭주 시 천장↑

**두 가지 적용 방법**

① **빠른 실험 (즉시 반영, 임시)** — 코드 고치기 전에 효과만 확인:
```powershell
# 예: stress 만 CPU 900m, HPA min3/max10/util45 로 즉시 변경
kubectl -n app set resources deploy/stress --requests=cpu=900m
$patch = '{"spec":{"minReplicas":3,"maxReplicas":10,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":45}}}]}}'
kubectl -n app patch hpa stress --type=merge -p $patch
kubectl -n app rollout status deploy/stress
# 다시 측정해서 perf% 올랐는지 확인
.\loadtest.ps1 http://<endpoint> 180s after
```
→ 좋으면 ②로 코드에 박는다. (이 patch는 `terraform apply`나 재배포 시 사라짐)

② **영구 반영** — 위 (1)(2) 숫자를 `k8s_apps.tf`에서 그 앱만 수정 후:
```powershell
cd ..\terraform ; terraform apply -auto-approve
```

**처방별 구체 예시 (전 → 후)**
| 상황 | 무엇을 | 전 → 후 |
|---|---|---|
| stress perf% 낮음(꼬리지연) | stress `cpu` | `300m → 900m` |
| stress 스케일이 느림 | stress HPA `util` / `min` | `55 → 45` / `2 → 3` |
| avail < 99% | 해당 앱 `min_replicas` | `2 → 3~4` |
| perf 100%인데 노드 과다 | user/product `cpu`/`util` | `300m → 200m` / `55 → 65` |
| 폭주에 천장 막힘 | `max_replicas` | `10 → 12` |

> 한 번에 하나씩만 바꾸고 → `loadtest`로 재측정 → 효과 확인. 여러 개 동시에 바꾸면 뭐가 효과인지 모름.

### autotune 우승값을 그대로 쓰면 안 되는 이유 (기본 모드)
기본 모드는 **모든 앱에 똑같은 cpu/util**을 적용해 비교한다. 그래서 우승값(예: `300m 균일`)을
그대로 박으면:
- user/product엔 **과함** → 노드 늘어 비용↑
- stress엔 **부족** → 성능 그대로

→ 해결책은 **`-App` 모드**: 병목 앱만 골라 `.\autotune.ps1 <ep> -App stress` 로 돌리면
그 앱만 patch/채점하므로 우승값을 **그 앱에 그대로 반영**해도 된다.
예) user/product `cpu=200m` 유지, stress 만 `-App` 으로 `750~900m` 탐색.

### 점수 읽을 때 주의
- `autotune`은 보통 **90초** 런이라 노이즈가 크다. 1~2점 차이는 **동률**로 본다.
- 점수 = `평균 perf% − (노드평균−2)×비용패널티 − (가용성<게이트면 −50)`.
  → 가용성 게이트(`AVAIL_GATE`, 기본 99%)를 못 넘기면 아무리 싸도 −50으로 탈락.

---

## 적용 절차 (영구 반영)

autotune의 `kubectl patch`는 **임시**(클러스터 재배포 시 사라짐). 진짜 반영은 코드 수정:

```hcl
# terraform/k8s_apps.tf — 앱별로 따로 설정
# 예) stress 만 CPU를 키우고 빨리 스케일
resource "kubernetes_deployment" "stress" {
  # ...
  resources {
    requests = { cpu = "900m", memory = "128Mi" }   # ← 무거운 앱만 ↑
  }
}
resource "kubernetes_horizontal_pod_autoscaler_v2" "stress" {
  spec {
    min_replicas = 3        # ← 시작부터 여유
    max_replicas = 10
    metric { resource { target { average_utilization = 55 } } }  # ← 낮출수록 빨리 스케일
  }
}
```

```powershell
cd ..\terraform ; terraform apply -auto-approve
```

> 요약: **perf% 낮은 그 앱 하나만** 골라 → `cpu↑` 또는 `HPA util↓/min↑` → 비용(`nodes avg`)과
> 균형 맞추고 → `k8s_apps.tf`에 박아서 `apply`. 가용성 99%는 무조건 사수.

---

## WAF 차단 분석 — `waf_header_stats.py`

대회 트래픽엔 **공격(비정상) 요청**이 섞여 들어온다. 그게 WAF에서 제대로 막히고 있는지,
**아직 안 막힌 게 뭔지**를 WAF 로그로 보여주는 도구. (WAF는 CloudFront에 붙어 있어 **로그는 us-east-1**)

### 한 줄 요약
> 이 스크립트를 돌리면 **"지금 막아야 할 것"** 이 맨 위에 딱 나온다. 거기 뭔가 있으면 → 그 패턴을
> `terraform/terraform.tfvars` 의 `waf_blocked_*` 변수에 추가하고 `apply` → 다시 돌려서 그 칸이 빌 때까지 반복.

### 1. 실행
```powershell
pip install boto3        # 최초 1회만
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```
- 로그그룹 이름 = `aws-waf-logs-<project>` (이 프로젝트는 `project=wsi2026` → `aws-waf-logs-wsi2026`).
- ⚠ **`--hours 1` 로 보라.** `--hours 24`는 *룰을 적용하기 전* 옛날 기록까지 섞여서, 이미 고친 것도
  "안 막혔다"고 보일 수 있다. 지금 상태를 보려면 짧게.

### 2. 출력은 3덩어리

**① WAF action 요약** — 전체가 얼마나 통과(ALLOW)/차단(BLOCK)됐나.
```
=== WAF action 요약 ===
  ALLOW    410210
  BLOCK    31146
```

**② ⚠ 아직 안 막힌 비정상 요청** ← **여기가 제일 중요.**
"막아야 할(403) 요청인데 WAF가 통과시킨 것"만 모아준다. **비어 있으면 다 잘 막고 있는 것.**
```
=== ⚠ 아직 안 막힌 비정상 요청 (막아야 할 것) ===
판정       WAF    status  cnt  endpoint  header           value
403-XFF  ALLOW  -       4    /v1/user  X-Forwarded-For  127.0.0.1, 10.0.0.1
```
> 위처럼 cnt가 3~4로 작으면 보통 **룰 적용 전 잔재**다. `--hours 1`로 다시 보면 사라진다.

**③ 전체 표** — 모든 (헤더 × 경로 × WAF처리 × 건수). `판정` 컬럼이 핵심.

### 3. `판정` 컬럼 읽는 법

| 판정 | 무슨 요청 | 어떻게 돼야 정상 |
|---|---|---|
| `OK` | 정상 트래픽 (Host=cloudfront, gzip, UA=hey/Go/curl, json, /images/*) | 통과 |
| `404` | **없는 경로** (`/.env` `/admin` `/v1/users` `/v2/user` `/v1/none`) | **404** (차단 아님!) |
| `403-UA` | 악성 User-Agent (sqlmap·nuclei 등 스캐너, attack) | **403 차단** |
| `403-XFF` | X-Forwarded-For 위조 (127.0.0.1, 사설 IP, 169.254.x) | **403 차단** |
| `SUSPECT` | **정상 트래픽에 없는 낯선 헤더** (`X-Junk`, `X-Debug` 등) | 값 보고 판단 — 공격이면 **403 차단**, 새 정상 스펙이면 무시 |

> 경로가 바뀐 날은 `--api-paths "/v2/user,/v1/product,..."` 로 유효 경로를 맞춰줘야 404 판정이 정확하다.

핵심 규칙 2개:
- **없는 경로(/.env 등)는 막는 게 아니라 404** 다. (스펙: "제공 API 외 = 404")
- **있는 경로(/v1/user 등)로 들어온 이상한 요청은 403** 으로 막는다.

### 4. ⚠ 헷갈리기 쉬운 것 2가지 (꼭 읽기)

**(가) `OK` 인데 `BLOCK` 인 행 = 오차단 아님.**
통계가 *헤더 하나하나* 기준이라, 어떤 요청이 X-Junk 때문에 막히면 **그 요청에 같이 들어있던
정상 헤더(Host·UA 등)까지 BLOCK으로 세어진다.**
```
OK  BLOCK  6137  /v1/user  Host  d35...cloudfront.net
```
이건 "정상 Host가 막혔다"가 아니라 **"다른 헤더 때문에 막힌 요청이 6137건 있다"** 는 뜻. 정상이다.

**(나) 진짜 오차단(정상이 막힘)은 이 표 말고 대시보드로 본다.**
대시보드 `avail%`가 100%면 정상 트래픽은 안 막히는 것. 떨어지면 그때 오차단 의심.

### 5. 대회 당일 — 새 공격 찾기 (패턴이 바뀐다)

`판정` 컬럼은 **아는 패턴만** 잡는다(sqlmap, X-Junk…). 대회날은 *처음 보는* 공격이 와서 `OK`로
보일 수 있다. **"아직 안 막힌"이 비어 있어도 전체 표를 눈으로 봐야 한다.**

#### 핵심: 정상을 외우고, 거기서 벗어나면 의심

**정상 트래픽은 항상 이렇게 생겼다 (이걸 기준선으로):**
- **User-Agent**: `hey/0.0.1`, `Go-http-client/1.1`, `curl/8.x`, (브라우저 `Mozilla/...`) — *요청 도구 이름*
- **헤더 종류**: `Host`, `Accept-Encoding`, `Content-Type`, `Content-Length`, `Accept` — *HTTP 표준 헤더*
- **값**: `...cloudfront.net`, `gzip`, `application/json`, 숫자 — *평범한 값*

**행마다 3가지만 물어본다:**

| 질문 | 정상 | 수상 (막을 후보) |
|---|---|---|
| ① 이 **헤더 이름**, 정상에도 있나? | Host / Accept-Encoding / Content-Type / Content-Length / Accept | **처음 보는 헤더** (`X-*`, `Referer` 등) |
| ② **User-Agent**가 아는 도구인가? | hey / Go / curl / 브라우저 | **도구·스캐너 이름** (sqlmap, Nuclei, nikto…) |
| ③ **값**이 뭔가 하려 하나? | cloudfront, gzip, 숫자 | **남의 도메인·경로·스크립트·쓰레기 문자** |

→ 하나라도 "수상"이고 **경로가 유효(`/v1/user|product|stress`)** 면 → **403 막을 후보**.
→ 단 **경로 자체가 없는 것**(`/wp-login.php`, `/.git/config`, `/admin`)이면 → 막는 게 아니라 **404**.

**예시로 감 잡기**
- `User-Agent: Nuclei …` → ②걸림(정상 UA 아닌 스캐너 이름) = **악성 UA**
- `Referer: http://evil.net/…` → ①+③걸림(정상에 없는 헤더 + 남의 악성 도메인) = **헤더 값**
- `X-Original-URL: /admin` → ①걸림(정상에 없는 헤더 + 값이 경로=우회 시도) = **비정상 헤더**
- `X-Forwarded-For: 127.0.0.1, …` → ③걸림(내부/루프백 IP = 위조)
- `/wp-login.php` → 경로가 없는 것 = **404** (막지 않음)

### 6. 막는 법 — **변수만 추가** (waf.tf 수정 불필요!)

WAF 커스텀 룰은 전부 **terraform 변수**로 생성된다. `terraform/terraform.tfvars` 에 값만 넣고 apply:

```hcl
# terraform/terraform.tfvars — 관찰 결과에 맞춰 필요한 것만
waf_blocked_user_agents   = ["sqlmap", "nikto", "attack"]                # (가) UA 에 포함되면 403
waf_blocked_headers       = ["x-evil", "x-debug"]                        # (나) 헤더가 존재하면 403 (소문자)
waf_blocked_header_values = [{ header = "referer", value = "evil.com" }] # (다) 헤더 값에 포함되면 403
waf_blocked_body_patterns = ["$ne", "sleep("]                            # (라) body 에 포함되면 403
waf_block_private_xff     = true                                         # (마) XFF 위조(사설 IP) 403
```

> * `waf_header_stats.py` 가 **"제안" 섹션**에 위 형식 그대로 뽑아준다 — 복붙하면 끝.
> * 오차단 걱정되면 `waf_custom_rule_action = "count"` 로 먼저 넣고 로그 확인 후 `"block"`.
> * 커스텀 룰은 유효 엔드포인트에서만 동작 → 없는 경로는 여전히 404 (스펙 준수).

### 7. 적용하고 확인

```powershell
# 변수 추가 후 적용 (Windows, Docker 켜져 있어야 함)
cd C:\Users\competitor\2026-terraform\3과제\terraform
terraform apply -auto-approve -var is_windows=true
```
```powershell
# 그 공격 흉내로 직접 호출 → 403 떠야 막힌 것
$EP = 'http://d35rfootcsla2a.cloudfront.net'
curl.exe -s -o NUL -w "%{http_code}`n" -H "X-Evil: 1" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"   # 403
# 없는 경로는 여전히 404 인지도 확인
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/.env"        # 404

# 다시 통계 — '아직 안 막힌' 칸이 빌 때까지 반복
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

> 정상 트래픽이 같이 막히면 안 된다 → **대시보드 avail% 100% 유지** 확인하면서 조이기.

---

## 🎯 대회 당일 체크리스트 (감 없이 그대로 따라하기)

> 헷갈리면 **여기만** 본다. 표의 **한 행씩** 아래 순서대로 기계적으로 처리.
>
> 🤖 **자동으로 하고 싶으면**: `waf_header_stats.py` 가 출력 하단 **「제안」 섹션**에
> `terraform.tfvars` 에 넣을 값을 그대로 뽑아준다 — 복붙 → apply → 재확인이 전부.
> (대시보드 「WAF분석」 탭의 HCL 룰 출력은 구버전 방식 — 지금은 변수 방식이 정답)

### STEP 0 — 돌리기
```powershell
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

### STEP 1 — 행마다 **경로**부터 본다 (헤더 말고 경로 먼저!)

`endpoint`가 아래 **유효 경로**인가?
```
/v1/user   /v1/product   /v1/stress   /healthcheck   /images/...
```
- **아니다** (예: `/.env` `/admin` `/wp-login.php` `/v1/users` `/v2/user` `/.git/config` `/backup.zip`)
  → **그냥 둔다. 404가 정답.** (막는 거 아님. 이미 ALB가 404 처리)
- **맞다** → STEP 2 로.

### STEP 2 — 유효 경로면, **이 행이 정상 화이트리스트에 있나** 확인

아래는 **정상**이다. 여기 있으면 그냥 둔다(통과가 정답):

| 헤더 | 정상 값 |
|---|---|
| `User-Agent` | `hey/...`, `Go-http-client/...`, `curl/...`, `Mozilla/...`(브라우저) |
| `Host` | 우리 cloudfront 도메인 |
| `Accept-Encoding` | `gzip` 등 |
| `Content-Type` | `application/json`, `multipart/form-data; ...`(이미지 업로드) |
| `Content-Length` | 숫자 |
| `Accept` | `*/*` 등 |

→ **화이트리스트에 없으면 = 공격. STEP 3 으로.**

### STEP 3 — 공격이면 **변수에 값만 추가** (waf.tf 안 고침)

| 이렇게 생겼으면 | 유형 | `terraform/terraform.tfvars` 에 추가 |
|---|---|---|
| `User-Agent`가 **도구/스캐너 이름** (sqlmap, nuclei, nikto, nmap, masscan, dirbuster, wpscan, "attack" 등) | 악성 UA | `waf_blocked_user_agents = ["sqlmap", "<새단어>"]` |
| **처음 보는 헤더**가 그냥 존재 (`X-Junk`, `X-Debug`, `X-Original-URL` …) | 비정상 헤더 | `waf_blocked_headers = ["x-debug"]` (소문자) |
| 헤더 **값**에 나쁜 게 들어감 (남의 도메인, 내부/메타데이터 IP `169.254.169.254`, SQL `' OR '1'='1`) | 헤더 값 | `waf_blocked_header_values = [{ header = "referer", value = "169.254.169.254" }]` |
| `X-Forwarded-For`에 **내부/루프백 IP** (`127.0.0.1`, `10.x`, `192.168.x`, `172.16~31.x`, `169.254.x`) | XFF 위조 | `waf_block_private_xff = true` |
| body 에 공격 토큰 (`$ne`, `sleep(`, `benchmark(` …) | body 패턴 | `waf_blocked_body_patterns = ["$ne"]` |

> `waf_header_stats.py` 의 **"제안" 섹션**이 위 값을 그대로 뽑아준다. 복붙 후 STEP 4.
> 확신 없으면 `waf_custom_rule_action = "count"` 로 먼저 관찰.

### STEP 4 — 적용 & 재확인
```powershell
cd C:\Users\competitor\2026-terraform\3과제\terraform
terraform apply -auto-approve -var is_windows=true
```
```powershell
# 그 공격 흉내로 호출 → 403 떠야 함
curl.exe -s -o NUL -w "%{http_code}`n" -H "X-Debug: 1" "http://<ep>/v1/user?email=x@x.org&requestid=1&uuid=1"   # 403
# 없는 경로는 여전히 404 인지
curl.exe -s -o NUL -w "%{http_code}`n" "http://<ep>/.env"   # 404
# 다시 통계 (공격이 BLOCK 으로 바뀌었는지)
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```
- 마지막에 **대시보드 avail% 100%** 확인 (정상 오차단 없는지).

### ⚠ 자주 틀리는 함정 3개 (이것만 외우기)
1. **헤더가 정상이어도 경로가 없으면 → 404** (막는 거 아님). 경로부터 봐라.
2. **값이 IP/URL이면 "무슨" 주소인지 봐라.** `169.254.169.254`(AWS 키 탈취)·내부IP·남의 도메인 = 공격.
3. **낯선 UA ≠ 공격.** `Mozilla/...`(브라우저)는 정상. **도구·스캐너 이름**만 막는다.

### 한 장 요약 (흐름)
```
행 →  경로가 유효?  ─아니오→  404 (그냥 둠)
            │ 예
            ▼
      정상 헤더/값?  ─예→  통과 (그냥 둠)
            │ 아니오
            ▼
      유형 찾아 변수에 값 추가 (UA / 헤더존재 / 헤더값 / XFF / body) → apply → 재확인
```
