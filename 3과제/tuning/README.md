# tuning/ — 공식 채점 · 라이브 Kubernetes 자동 튜닝

## 🚨 0단계: PowerShell 실행 정책 (이거 안 하면 모든 .ps1 이 안 돈다)

`.\setup.ps1` · `.\loadtest.ps1` · `.\optimize.ps1` · `..\tools\dashboard.ps1` 이 아래 오류로
전부 막히면 실행 정책 때문이다.

```
.\dashboard.ps1 : 이 시스템에서 스크립트를 실행할 수 없으므로 ... 파일을 로드할 수 없습니다.
    + FullyQualifiedErrorId : UnauthorizedAccess
```

**한 번만 실행하면 끝. 관리자 권한 필요 없다.**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

`RemoteSigned` 는 로컬 스크립트는 서명 없이 허용하고 인터넷에서 받은 것만 서명을 요구한다.
`Bypass`/`Unrestricted` 보다 안전하므로 이걸 쓴다.

적용했는데도 같은 오류가 나면 ZIP 으로 받아 파일에 차단 표시가 붙은 경우다:

```powershell
Get-ChildItem ..\.. -Recurse -Filter *.ps1 | Unblock-File
```

정책을 바꾸고 싶지 않으면 그때만 우회한다:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2
```

> `npm` 도 같은 이유로 막힌다(`npm.ps1` 로드 실패). 그때는 `npm.cmd run dev` 처럼 `.cmd` 를
> 직접 부르면 정책과 무관하게 실행된다.

---

## ⚠ 먼저: `hey` 설치 (setup.ps1 이 403 으로 실패할 때)

`setup.ps1` 이 아래처럼 실패하면 **Go 로 직접 빌드**해야 한다.

```
installing hey...
  S3 download failed: 원격 서버에서 (403) 사용할 수 없음 오류를 반환했습니다.
  hey.exe 깨짐/실패 → Go 빌드로 폴백...
  Go 미설치 → winget install --id GoLang.Go -e 후 재실행하거나
```

배포 바이너리를 받을 방법이 **하나도 없다**(2026-08 확인):

| 경로 | 상태 |
|---|---|
| `hey-release.s3.us-east-2.amazonaws.com` (setup.ps1 기본) | **403** — 버킷 공개 중단 |
| GitHub `rakyll/hey` releases | 릴리스 5개 전부 **바이너리 자산 없음** |
| `winget install hey` | **패키지 없음** (검색 결과 무관한 앱만) |

→ **Go 설치 후 소스 빌드가 유일한 방법.** `loadtest.ps1` / `optimize.ps1` 은 `hey` 가 없으면
바로 `exit 1` 이므로 우회할 수 없다.

### 설치 — 새 PC에서 이 블록 그대로 복붙

검증 완료: Go 1.26.7 → hey v0.1.5 (11.55MB). **현재 창에서 끝난다. 새 창 필요 없음.**

```powershell
# 1) Go 설치 (UAC 승인 필요). 이미 있으면 "사용 가능한 업그레이드 없음" 이라 나오고 넘어간다.
winget install --id GoLang.Go -e --source winget --accept-package-agreements --accept-source-agreements

# 2) 현재 창의 PATH 갱신  ← 이걸 빼먹으면 다음 줄에서 "'go' 용어가 인식되지 않습니다" 가 난다.
#    winget 이 PATH 에 C:\Program Files\Go\bin 을 넣지만 이미 열려 있는 창에는 반영되지 않는다.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

# 3) hey 빌드 → %USERPROFILE%\bin 에 설치 (모듈 다운로드로 30~60초)
$env:GOBIN = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Force -Path $env:GOBIN | Out-Null
go install github.com/rakyll/hey@latest

# 4) %USERPROFILE%\bin 을 사용자 PATH 에 영구 등록 (setup.ps1 도 하지만 순서상 먼저 해둔다)
$u = [Environment]::GetEnvironmentVariable('Path','User')
if ($u -notlike "*$env:GOBIN*") { [Environment]::SetEnvironmentVariable('Path', "$env:GOBIN;$u", 'User') }
$env:Path = "$env:GOBIN;$env:Path"

# 5) 확인 — "Usage: hey [options...] <url>" 가 나오면 성공
hey
```

**이미 hey 를 깔아본 PC라면** 3번을 다시 돌릴 필요 없다. 2번만 실행하면 `hey` 가 바로 잡힌다:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
hey    # Usage 가 나오면 그대로 사용 가능
```

### 자주 걸리는 곳

| 증상 | 원인 / 해결 |
|---|---|
| `'go' 용어가 인식되지 않습니다` | 위 2번 PATH 갱신을 안 했다. 그 줄만 실행하고 재시도 |
| `'hey' 용어가 인식되지 않습니다` | 같은 이유. 2번 실행 후 재시도 |
| winget 이 "사용 가능한 업그레이드 없음" | Go 가 이미 깔려 있다는 뜻 — 정상, 2번으로 넘어간다 |
| `go install` 이 프록시/네트워크 오류 | `$env:GOPROXY='direct'` 후 재시도 |

### 그 다음

```powershell
.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2
```

`hey` 가 이미 있으면 setup.ps1 은 다운로드를 건너뛰고 kubectl + kubeconfig 만 처리한다.
`%USERPROFILE%\bin` 은 setup.ps1 이 사용자 PATH 에 영구 등록하므로 새 창부터 `hey` 가 바로 잡힌다.

> **정말 Go 를 못 깔면**: `../../부하/` 의 웹 도구(`python server.py`)로 부하는 줄 수 있지만,
> `loadtest.ps1` 의 채점 환산·`optimize.ps1` 의 자동 튜닝은 쓸 수 없다. 되도록 Go 를 깐다.

---

3과제 40점은 **전부 부하 테스트 결과**로 매겨진다. `advise.py`, `optimize.py`, `score.py`,
대시보드는 모두 **`rubric.py` + `tuning_engine.py` 한 엔진**을 쓴다.

| 채점 항목 | 배점 | 도구 |
|---|---|---|
| 비정상 요청 처리 (403/404) + 이미지 다운로드 | 4 | `verify.ps1` |
| 가용성 (앱별 2xx & 5초 이내) | 12 | `loadtest.ps1` |
| 성능 (user·product ≤0.2s, stress ≤1.0s) | 12 | `loadtest.ps1` |
| 비용 (인스턴스 비용 ratio) | 12 | `loadtest.ps1` + `optimize.ps1` |

---

## 목적함수: 비용도 성능도 아니고 총점

비용 12점과 성능·가용성 24점은 맞바꿀 수 있다. 한쪽을 목적함수로 두면 반대쪽에서 더 큰 점수를
흘린다. 엔진은 **노드 수 → 총점 곡선**을 그려 총점이 최대인 운영점을 고르고, 후보 탐색은 그
지점을 겨냥한다.

### 비용 ratio의 분모(B)는 비공개다 — 그래서 하나로 찍지 않는다

40점 중 **성능+가용성 24점은 B와 완전히 무관**하다. B가 흔드는 건 비용 12점뿐이다. 그래서
곡선의 '품질' 축은 확정값으로 그릴 수 있고, 불확실성은 비용 축에만 남는다.
`--cost-baselines`(기본 `2,3,4`)로 준 후보 전체에서 평가한 뒤 두 값을 낸다.

- `expected_nodes` — B 균등 가중 **기대 총점** 최대
- `minimax_nodes` — 어떤 B가 진짜여도 **최악 손해(regret)가 가장 작은** 값 ← 추천값

B별 최적이 모두 같으면 `robust: true`. 즉 **분모를 몰라도 답이 확정**인 경우가 많다.

> **하한 절벽: `ratio < 0.50`이면 비용 12점이 통째로 0이다.** 그래서 "노드가 적을수록 유리"가
> 성립하지 않고, 저구간에서는 노드를 늘리는 쪽이 이득이다. 엔진이 Pareto 가지치기 대신
> 구간 전체를 평가하는 이유다.

### 곡선 읽는 법 — `python optimize.py <outdir> --frontier`

```
  노드   품질   느려짐   B=2    B=3    B=4   기대총점  최악손해
     1   14.0    3.98   14.0   14.0   14.0    14.00    14.00  [성능<30% -> 비용 0점]
     2   15.5    1.99   27.5   27.5   27.5    27.50     0.50  <== 추천
     4   16.0    0.99   24.0   26.0   28.0    26.00     3.50
     7   16.0    0.57   18.0   22.0   25.0    21.67     9.50
```

`품질`은 성능+가용성 24점이고 B와 무관한 확정값이다. 위 예에서 2대→7대로 노드를 3.5배 써도
품질은 +0.5점뿐인데 비용은 최대 9.5점을 잃는다 — **성능이 CPU가 아니라 DB에 묶여 있다는
신호**라 노드를 사면 안 된다. 반대로 품질 열이 노드에 따라 크게 오르면(CPU 바운드) 비용 몇
점을 내주고 노드를 늘리는 쪽이 총점에서 이긴다.

`perf_gate_ok=false` 행은 성능 30% 미달로 **비용 12점이 전부 0**이 되는 구간이다.

---

## 인스턴스 타입이 바뀌어도 동작한다

- **사이징**: 노드 CPU/메모리 allocatable·AZ 수·시스템 예약을 `kubectl`로 **실측**한다.
  상수가 없으므로 타입을 바꾸면 자동으로 따라간다.
- **비용 축**: 채점은 대수가 아니라 인스턴스 **비용**의 비율이다. t3.large 2대는 t3.medium
  2대와 대수가 같지만 비용은 2배다. 엔진은 노드 라벨에서 타입을 읽어 기준 타입 대비
  상대 비용(`node_cost_weight`)을 곱해 환산한다. 같은 패밀리면 크기 단위 비로 정확하다
  (`large = medium × 2`). 패밀리가 다르면 근사치이며 10~20% 오차가 날 수 있다.

| 환경변수 | 용도 |
|---|---|
| `TUNE_NODE_REFERENCE` | 비용 기준 인스턴스 타입 (기본 `t3.medium`) |
| `TUNE_NODE_COST_WEIGHT` | 상대 비용을 직접 지정 (패밀리가 달라 근사가 불안할 때) |
| `TUNE_BASELINE_NODES` | 비용 ratio 분모의 점 추정값. `config.ps1`이 설정한다 |

---

## 파일

| 파일 | 역할 |
|---|---|
| `setup.ps1` | `hey.exe`·`kubectl.exe` 설치(`%USERPROFILE%\bin`) + kubeconfig 작성 |
| `config.ps1` | **대회날 여기만 고친다.** 엔드포인트·API 목록·SLO·부하 모양·게이트 |
| `verify.ps1` | 응답코드 규약 검증 (정상 2xx / 비정상 403 / 미정의 404 / 이미지 200) |
| `loadtest.ps1` | 채점 방식 부하 측정 → 리포트 + 권장값 (+ `podcpu.csv`·`nodes.csv` 실사용 기록) |
| `optimize.ps1` | **18분 트랜잭션 runner** — 측정·적용·채택 또는 정확한 snapshot 롤백 |
| `rubric.py` | 공식 rate band·비용 곡선·성능 게이트의 단일 구현 |
| `tuning_engine.py` | 라이브 snapshot, 병목 분류, 프론티어, 후보·명령 생성 |
| `optimize.py` | 엔진 결과를 runner에 JSON으로 전달 + `--frontier` 표 출력 |
| `score.py` / `advise.py` | hey CSV 채점 CLI / 비파괴 권장값 출력 |
| `autotune.ps1` | 완료된 부하 결과로 권장값만 계산(자동 변경 없음) |
| `waf_header_stats.py` | WAF 로그 분석 → 안 막힌 비정상 패턴 + tfvars 제안 |

---

## 빠른 시작

```powershell
cd C:\Users\competitor\2026-terraform\3과제\tuning
Set-ExecutionPolicy -Scope Process Bypass -Force      # 스크립트가 막히면

.\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2
kubectl -n app get pods                               # 클러스터 보이는지

.\verify.ps1                                    # 1) 응답규약 4점 먼저
.\loadtest.ps1 -Duration 120s -Label baseline   # 2) 가용성/성능/노드 측정 (~2.5분)
.\optimize.ps1 -Apply                           # 3) 18분 안에서 라이브 총점 최적화
```

엔드포인트는 `..\terraform` 의 `terraform output -raw endpoint` 에서 자동으로 읽는다.
다른 주소는 `-Url http://...` 또는 `$env:ENDPOINT`.

> 결과가 전부 `NO DATA` 면 `hey` 손상이다. `(Get-Item $env:USERPROFILE\bin\hey.exe).Length`
> 가 1MB 미만이면 삭제 후 `winget install --id GoLang.Go -e` → 새 창 →
> `$env:GOBIN="$env:USERPROFILE\bin"; go install github.com/rakyll/hey@latest`.

---

## config.ps1 — 대회날 고치는 곳

앱/경로/SLO가 바뀌면 **여기만** 고친다. terraform 변수를 바꿔도 자동 반영되지 않는다.

| 항목 | 의미 |
|---|---|
| `$APIS[].name` | 결과 라벨 + 같은 이름의 Deployment/HPA를 튜닝 |
| `$APIS[].slo` | 채점기준의 성능 SLO(초) |
| `$APIS[].conc` / `qps` | `hey -c` / `-q`. `-q`는 **worker당** QPS라 총 부하 = `conc × qps` |
| `$APIS[].keys` / `pathFmt` | 요청 키 분산. `{KEY}` 자리에 키가 들어간다 |
| `$KEY_PREFIX` / `$KEY_MIN` / `$KEY_MAX` / `$KEY_SPREAD` | 덤프의 실제 키 공간과 분산 개수 |
| `$HC_PATH` / `$IMAGES_PREFIX` | 헬스체크·이미지 경로 (terraform 변수와 맞춘다) |
| `$COST_BASELINE_NODES` | 비용 ratio 분모의 점 추정값 (**기준 인스턴스 대수** 단위) |
| `$AVAIL_GATE` | 가용성 합격선(99%) |

> ⚠ **고정 키 하나로 때리면 안 된다.** 실측 사고: product를 고정 id로만 때렸더니 CloudFront가
> 그 하나를 캐싱해 측정이 99.7%였는데, 채점 트래픽은 여러 id를 써서 실제는 77.2%였다.
> 그 낙관적 측정 위에서 뽑은 값이 실제 트래픽에서 안 들어 user 29.5%(비용 12점 전부 상실)로
> 이어졌다. `$KEY_SPREAD`로 부하를 쪼개야 캐시 히트율이 채점과 비슷해진다.

---

## optimize.ps1

```powershell
.\optimize.ps1                          # 제안만 — 클러스터 불변
.\optimize.ps1 -Apply                   # 18분 예산으로 실제 탐색·적용
.\optimize.ps1 -Apply -LoadScale 0.5    # 채점 부하가 측정보다 가벼울 때
.\optimize.ps1 -Apply -TargetRps "user=100,product=200,stress=10"   # rps를 직접 고정
.\optimize.ps1 -Apply -CostBaselines '3,4,6'    # 기준 구성이 더 크다고 볼 때
.\optimize.ps1 -Apply -Duration 180s    # 측정 창을 더 길게
```

**부하량에 정규화해서 계산한다.** 부하와 무관한 값인 *요청당 CPU 시간*을 구해 목표 부하에
곱한다: `필요 CPU = 요청당 CPU × 목표 rps`, `request = 필요 CPU ÷ 파드수`. 그래서 부하를 세게
넣고 측정해도 request가 과대해지지 않는다.

**request는 실측 사용량에서 벗어나지 않는다.** 파드당 실사용의 절반이 하한이고, 한 회차에
현재값의 절반 아래로는 내리지 않는다.

**Source of truth는 Terraform 파일이 아니라 라이브 Deployment/HPA다.** 튜닝 명령은 현재
라이브 값을 읽어 적용하고 같은 snapshot으로 정확히 롤백한다. Terraform drift는 정상이며,
튜닝 루프에 `terraform apply`를 넣지 않는다.

단위 테스트: `py -3 -m unittest test_tuning`

---

## 대회날 순서

| 시점 | 할 일 |
|---|---|
| 배포 직후 | `.\verify.ps1` — 응답규약 4점 (FAIL이면 다른 것보다 먼저) |
| 트래픽 전 ~3분 | `.\loadtest.ps1 -Duration 120s -Label t1` — 채점 환산 + 원인 진단 |
| 트래픽 전 ~18분 | `.\optimize.ps1 -Apply` — 프론티어로 운영점 결정 후 라이브 적용 |
| 트래픽 중 | `python waf_header_stats.py ...` → 패턴 차단 → `.\verify.ps1` 재확인 |
| 트래픽 중 | `.\loadtest.ps1 -Label during -Duration 90s` — 추세만 짧게 |

> ⏱ **트래픽 전 1시간 = `terraform apply`(~30분) + 튜닝(~20분).** 측정이 너무 짧으면
> 콜드스타트가 섞여 성능이 실제보다 낮게 찍힌다.

### 지켜야 할 것

- **부하 중에는 HPA만 만진다.** `requests` 변경(`kubectl set resources`, 파드 템플릿을 바꾸는
  `terraform apply`)은 롤아웃을 일으키고 **롤아웃 자체가 504**를 만든다. request 사이징은
  트래픽 시작 전에 끝낸다.
- **성능 30%는 비용의 전제조건이다.** 세 앱 중 하나라도 미달이면 비용 12점이 통째로 0이다.
  비용을 줄이려 성능을 깎는 방향은 30% 선 근처에서 금지다.
- **request를 올리기 전에 확인.** 실사용이 request의 절반도 안 되는데 느리면 CPU가 병목이
  아니다. `advise.py`가 `CPU 병목 아님`으로 판정하면 DB(RDS CPU·커넥션·쿼리지연)·CloudFront
  캐시 히트율·커넥션풀 borrow 대기를 본다.
- **`max_replicas`는 성능 천장이면서 비용 천장이다.** 지속 부하에서는 상한까지 실제로 파드와
  노드가 늘어난다. 감으로 크게 열지 말고 실측 총점과 평균 노드 수를 함께 보고 정한다.
- Karpenter `consolidateAfter`/`budgets`와 DB 설정은 **자동 변경하지 않는다.** 엔진은 이들을
  후보 판단에 반영만 하고, 인프라·DB 변경은 별도 고위험 작업으로 남긴다.

인프라 쪽 값을 바꿔야 하면 → [`../terraform/README.md`](../terraform/README.md) 의
**"무엇을 바꾸려면 어디를"** 표.
