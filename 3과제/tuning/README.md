# tuning/ — 부하 테스트 & 자동 튜닝 (AWS CloudShell 기준)

대회 채점 방식(가용성 / 성능효율 / 비용)과 동일하게 부하를 걸고, HPA·request 값을
**자동으로 스윕해 최적값을 찾는** 도구 모음. **AWS CloudShell**에서 바로 돌아간다.

> ⚠️ 절대값(예: `cpu 500m`)은 **앱마다 다르다**. 대회날 새 앱을 받으면 `config.env`만
> 고쳐 `autotune.sh`로 그 자리에서 최적값을 다시 찾는 게 이 도구의 목적이다.
> terraform 의 기본값은 "앱 안 타는 견고한 출발점"일 뿐, 정답이 아니다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `config.env`         | **대회날 여기만 수정** — 엔드포인트 API 목록·SLO·부하파라미터·시드 |
| `cloudshell-setup.sh`| CloudShell 부트스트랩 (hey·kubectl 설치 + kubeconfig) |
| `loadtest.sh`        | 1회 부하 + 채점식 측정 (가용성/perf/노드수) |
| `autotune.sh`        | 조합 그리드 자동 스윕 → 채점 → 우승자 적용 |
| `autotune-hc.sh`     | 힐클라이밍 정밀탐색 (노드 드레인으로 노이즈↓) |

---

## CloudShell 빠른 시작

CloudShell은 **리소스가 떠 있는 그 AWS 계정**에서 연다(콘솔 우상단 `>_` 아이콘).
크레덴셜은 자동(ambient) — **프로파일 지정 불필요**.

```bash
# 0) 도구 받기 (이 레포의 tuning 폴더)
git clone https://github.com/gmst-cc/wsi-2026-task3.git
cd wsi-2026-task3/tuning

# 1) 부트스트랩 — hey/kubectl 설치 + kubeconfig (클러스터명/리전)
./cloudshell-setup.sh wsi2026-cluster ap-northeast-2

# 1-1) 현재 셸 PATH 적용 (직접 kubectl/hey 칠 때 필요. 새 세션은 자동)
export PATH="$HOME/bin:$PATH"

# 2) 클러스터 보이는지 확인
kubectl -n app get pods

# 3) 엔드포인트 확인 (terraform output 또는 CloudFront 콘솔)
#    예: http://dj1k92w9552mb.cloudfront.net

# 4) baseline 측정
./loadtest.sh http://<endpoint> 180s baseline

# 5) 최적값 자동 탐색
./autotune.sh http://<endpoint> 90s
```

### hey 설치 실패 시 (loadtest가 전부 `NO DATA`)
`cloudshell-setup.sh`는 hey를 공식 S3 미러에서 받는데, 이 미러가 **403(AccessDenied)** 를
내면 깨진 파일(에러 XML)이 `~/bin/hey`로 저장돼 실행이 안 되고 측정이 `NO DATA`로 나온다.
확인·복구:

```bash
# 진단: 깨졌으면 XML/200바이트 내외 + 실행 시 'syntax error near ... <?xml'
hey -h 2>&1 | head -1
head -c 200 ~/bin/hey

# 복구: hey를 Go로 직접 빌드 (다른 도구로 바꾸는 게 아니라 hey 그대로)
sudo dnf install -y golang
GOPATH=/tmp/go GOCACHE=/tmp/gocache GOBIN="$HOME/bin" go install github.com/rakyll/hey@latest
hey -h | head -1     # usage 뜨면 정상
```
> 빌드 캐시는 `/tmp`(overlay, 넉넉)로 빼 1GB 홈을 안 쓴다. S3 미러가 복구되면 위 과정 불필요.

> CloudShell은 홈(`~`) 1GB만 영속이고 컴퓨트는 세션 종료 시 초기화된다.
> `~/bin`(설치물)과 `~/.kube/config`는 남고, `/tmp`의 결과 CSV는 세션 한정.

### CloudShell이 아닌 환경
- **macOS**: `brew install hey kubectl awscli python3`
- **Linux**: `cloudshell-setup.sh`가 그대로 동작(Amazon Linux/Ubuntu 공통, `~/bin` 설치).
- **Windows**: WSL2 우분투에서 Linux와 동일하게.
- CloudShell이 아니면 본인 계정 자격증명이 필요(`aws configure` 또는 프로파일).
  이 프로젝트의 리소스 생성은 **`lee` 프로파일** 전제 — 단, CloudShell은 ambient라 불필요.

---

## config.env — 대회날 채우는 곳

```bash
APIS=(
  # name | slo_sec | conc | qps | METHOD | path(쿼리포함) | json_body(POST만)
  "user|0.2|30|10|GET|/v1/user?email=loadseed1@example.org&...|"
  "product|0.2|30|10|GET|/v1/product?id=loadseedp1&...|"
  "stress|1.0|12|2|POST|/v1/stress|{...json...}"
)
SEEDS=( "POST|/v1/user|{...}" "POST|/v1/product|{...}" )  # GET 부하가 맞힐 행 미리 삽입
AVAIL_GATE=99      # 가용성 합격선(%); 미만이면 autotune 점수 실격
COST_PENALTY=6     # 노드 평균 1대 초과당 감점
NS=app             # k8s 네임스페이스
```
- `name`은 **같은 이름의 Deployment**를 autotune이 튜닝한다(앱 이름 = Deployment 이름 전제).
- `slo_sec`는 채점기준표의 성능 기준을 그대로 넣는다.

---

## loadtest.sh

```bash
./loadtest.sh <endpoint> [duration] [label]
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
- 산출물: `/tmp/tune-<label>/{<api>.csv, nodes.csv}`.

## autotune.sh — 그리드 자동 스윕

```bash
./autotune.sh <endpoint> [duration]
```
- config의 모든 앱에 **균일한 (cpu·util·min·max)** 조합을 차례로 적용(live `kubectl patch`, terraform 재apply 없음).
- 조합당: patch → rollout → 45s 안정화 → loadtest → 채점.
- 점수 = `평균 perf% − 노드비용패널티 − (가용성<GATE면 실격)`.
- 끝나면 **우승 조합을 클러스터에 적용**하고 terraform 반영값을 출력.
- 조합은 스크립트 상단 `COMBOS`에서 추가/수정.

## autotune-hc.sh — 힐클라이밍 정밀탐색

```bash
./autotune-hc.sh <endpoint> [duration] [start_cpu] [start_util] [max_moves]
```
- 시작점에서 cpu(±100m)·util(±5)을 흔들어 점수 개선 방향으로 이동(first-improvement).
- 매 trial 전 **노드를 baseline까지 드레인**(Karpenter consolidation 대기) → 비용 측정 노이즈↓.
- `autotune.sh`로 대략 우승 영역 찾은 뒤, 그 근처를 정밀화할 때 사용.

---

## 대회날 워크플로 (요약)

1. 리소스 띄운 계정에서 **CloudShell** 열기 → `git clone` → `cd tuning`.
2. `./cloudshell-setup.sh <cluster> <region>`.
3. 받은 앱·채점기준표 보고 **`config.env`의 APIS/SEEDS/SLO 수정**.
4. `./loadtest.sh <ep> 180s baseline`로 현재 상태 확인.
5. `./autotune.sh <ep> 90s`로 최적 조합 선정 → 필요하면 `autotune-hc.sh`로 정밀화.
6. 출력된 값으로 `terraform/k8s_apps.tf` 수정 후 `terraform apply` (영구 반영).

> 부하는 Karpenter 노드를 띄워 **비용 발생**. 끝나면 consolidation(~60s) 확인,
> 종료 시 `terraform destroy`.

---

## 결과 쉽게 읽는 법 (초보용)

`loadtest.sh` / `autotune.sh` 출력을 한 줄씩 풀면:

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
```bash
# 예: stress 만 CPU 900m, HPA min3/max10/util45 로 즉시 변경
kubectl -n app set resources deploy/stress --requests=cpu=900m
kubectl -n app patch hpa stress --type=merge -p \
  '{"spec":{"minReplicas":3,"maxReplicas":10,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":45}}}]}}'
kubectl -n app rollout status deploy/stress
# 다시 측정해서 perf% 올랐는지 확인
./loadtest.sh http://<endpoint> 180s after
```
→ 좋으면 ②로 코드에 박는다. (이 patch는 `terraform apply`나 재배포 시 사라짐)

② **영구 반영** — 위 (1)(2) 숫자를 `k8s_apps.tf`에서 그 앱만 수정 후:
```bash
cd terraform && terraform apply -auto-approve
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

### autotune 우승값을 그대로 쓰면 안 되는 이유
`autotune.sh`는 **모든 앱에 똑같은 cpu/util**을 적용해 비교한다. 그래서 우승값(예: `300m 균일`)을
그대로 박으면:
- user/product엔 **과함** → 노드 늘어 비용↑
- stress엔 **부족** → 성능 그대로

→ 우승값은 "대략 어느 방향"만 참고하고, **실제 반영은 앱별로 다르게** 한다.
예) user/product `cpu=200m`, stress `cpu=750~900m`.

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

```bash
cd terraform && terraform apply -auto-approve
```

> 요약: **perf% 낮은 그 앱 하나만** 골라 → `cpu↑` 또는 `HPA util↓/min↑` → 비용(`nodes avg`)과
> 균형 맞추고 → `k8s_apps.tf`에 박아서 `apply`. 가용성 99%는 무조건 사수.
