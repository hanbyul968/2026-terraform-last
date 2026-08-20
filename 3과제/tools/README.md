# tools/ — 모니터링 대시보드

트래픽이 들어오는 동안 **어디가 깨졌고 무엇을 고쳐야 하는지** 한 화면에서 보는 도구.
클러스터·앱·WAF 상태를 모아 4xx/5xx의 원인과 해결 명령까지 뽑아준다.

| 파일 | 용도 | 설치 |
|---|---|---|
| `monitor.py` | 표준 라이브러리만. **터미널 출력** + 자체 웹서버 | 없음 |
| `dashboard.py` | Flask 다크 UI (시간창 선택·자동 갱신). 수집 로직은 `monitor.py` 재사용 | `pip install flask` |
| `dashboard.ps1` | Windows 런처 (flask 자동 설치 + 브라우저 열기) | — |
| `tunnel.sh` | CloudShell 에서 웹 UI 를 노트북 브라우저로 보기 (cloudflared) | — |

**어느 걸 쓰나**

- CloudShell + 브라우저 필요 없음 → `python3 monitor.py --watch 10`
- CloudShell + 웹 UI 보고 싶음 → `bash tunnel.sh`
- 로컬 PC(Windows) → `.\dashboard.ps1`

---

## 사전 준비

```bash
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
kubectl -n app get pods        # 보이면 준비 완료
```

`kubectl`(현재 컨텍스트가 대상 EKS) · `aws` CLI 자격증명 · `python3` 필요.
CPU/MEM 사용률은 metrics-server 가 있어야 나온다(이 프로젝트는 EKS 애드온으로 설치됨).

---

## A. CloudShell — 터미널 (대회 기본)

```bash
cd ~/2026-terraform/3과제/tools
python3 monitor.py --once --since 15m              # 1회 스냅샷
python3 monitor.py --watch 10 --since 15m          # 10초마다 갱신 (Ctrl+C)
```

출력 순서: 요약(allow/block · 2xx/4xx/5xx · pod · node) → 앱별 카운트 + 최근 5xx/4xx
→ Pod(상태/재시작/CPU·MEM/사유) → 노드 → WAF → **진단(원인·해결)**.

## B. 로컬 PC (Windows) — 웹 UI

```powershell
cd C:\Users\competitor\2026-terraform\3과제\tools
.\dashboard.ps1                                    # http://localhost:8080 자동 열림
.\dashboard.ps1 -Port 9090 -Namespace app
.\dashboard.ps1 -Demo                              # 클러스터 없이 레이아웃만 확인
```

flask 가 없으면 자동 설치한다. 종료는 Ctrl+C.

## C. CloudShell — 웹 UI (cloudflared 터널)

CloudShell 은 localhost 포트로 브라우저 직접 접속이 안 된다(Cloud9 과 다름). `tunnel.sh` 가
cloudflared 설치 → 대시보드 백그라운드 실행 → 공개 URL 출력까지 한 번에 처리한다.

```bash
pip3 install --user flask                          # 최초 1회
bash tunnel.sh                                     # 기본 PORT=8080 NS=app
PORT=8080 NS=app WAF=aws-waf-logs-wsi2026 bash tunnel.sh
```

출력되는 `https://xxxx.trycloudflare.com` 을 노트북 브라우저에 붙여넣는다.

> ⚠ **터널 URL 은 인증이 전혀 없다.** 주소만 알면 누구나 클러스터 정보를 본다.
> 확인용으로 잠깐만 쓰고 즉시 종료할 것.

```bash
pkill -f dashboard.py ; pkill cloudflared          # 정리 (Ctrl+C 후에도 남을 수 있음)
```

안 뜨면 `cat /tmp/dash.log`(flask 미설치가 가장 흔함), 주소가 안 나오면 `cat /tmp/cloudflared.log`.

---

## 탭 구성

| 탭 | 내용 |
|---|---|
| 개요 | allow/block 합계, 2xx·4xx·5xx, Pod ready/총, 노드 수, 앱별 요약 카드, 진단 |
| 앱별 탭 (라이브 Deployment/HPA에서 자동 발견) | 성능%(2xx & ≤SLO ÷ 전체)·가용성%(2xx & ≤5s ÷ 전체)·p50/p95/p99, 2xx/4xx/5xx, 경로별·에러경로, 최근 요청(2xx/4xx/5xx 분리) |
| Pod | Pod 별 상태/재시작/CPU·MEM/노드/오류사유(CrashLoop·OOM 등) |
| 노드 | 노드 수·타입(karpenter/base)·Ready·CPU/MEM, HPA 현황 |
| WAF | 차단(403) 룰/IP/URI/메서드 + 최근 차단 (allow 와 분리) |
| WAF분석 | `waf_header_stats.py` 출력을 붙여넣으면 → 아직 안 막힌 공격 + tfvars 값 + 테스트 curl (오프라인) |
| 계산 | **원인을 먼저 구분한 뒤** 앱별 늘려/줄여/유지 판정 + 반영값 (아래 참고, CLI 판은 `tuning/advise.py`) |
| 진단 | Pod 크래시·5xx·4xx·성능저하 원인 + 해결 명령 |

### 계산 탭이 request 를 다루는 방식

`requests.cpu` 는 **노드 예약량이지 파드 속도 상한이 아니다.** user/product 에는 cpu limit 이 없어서
request 를 올려도 파드가 빨라지지 않는다. 올리면 오히려 이렇게 된다.

- 노드당 파드 수가 줄어 **노드가 늘고 비용이 오른다**
- HPA 사용률 = 실사용 ÷ request 가 작아져 **스케일업이 늦어진다** (성능이 더 나빠질 수 있다)

그래서 "느리다 → request 올려" 는 틀린 처방이다. 계산 탭은 `tuning/tuning_engine.py`(CLI와 동일한
공통 엔진)의 실측 계산을 그대로 보여준다.

```text
요청당 CPU = 총 CPU ÷ 초당 요청수                        ← 부하량과 무관한 값
필요 CPU   = 요청당 CPU × 목표 rps                       ← 목표 부하 기준(측정 부하 아님)
권장 request = 필요 CPU ÷ 파드수   (하한: 그 절반, 현재값의 절반)
예상 노드 = ceil((앱별 request × 예상 replica) / (allocatable − 노드당 DaemonSet 예약)) × 보정계수
CPU 비중  = 요청당 CPU ÷ 평균 지연                        ← 앱마다 매번 측정
예상 지연 = 실측 지연 × (1 + (CPU 공급부족배수 − 1) × CPU 비중)
```

| 상황 | 판정 | request |
|---|---|---|
| 가용성 < 90% 또는 성능 < 80% (유지선) | 유지선 위반 | **유지.** `target`↓·`min`/`max` 조정 우선 |
| 파드가 `max_replicas` 에 붙음 | 파드 상한 도달 | 유지, `max_replicas` 올림 |
| 실사용이 request 의 절반 미만 + 노드 CPU 낮음 | CPU 병목 아님 | 올리지 않음. DB·캐시·커넥션풀을 본다 |
| 목표 부하 필요 CPU보다 예약이 큼 | 과투자 | 내림 (노드↓ = 비용↓) |
| 파드당 필요 CPU의 절반 미만으로 내려감 | 비현실적 예약 | 제안하지 않음 |
| 내렸을 때 CPU 공급부족이 한도를 넘음 | 외삽 불가 구간 | 그만큼은 제안하지 않음. 한 단계씩 실측 |

측정 부하가 채점 부하보다 세면 값이 과대해지므로, 목표 부하를 `optimize.ps1 -LoadScale`/`-TargetRps`로
지정한다. 예측은 항상 120초 실측으로 확정한다. 앱 목록·SLO·Deployment/HPA 이름·요청당 CPU·CPU 비중을
매 측정에서 다시 읽으므로 **대회날 앱이 바뀌어도(이름·개수·SLO·워크로드 성격 변경) 그대로 쓴다.**

⚠ 부하 도는 중에 `requests` 를 바꾸면 **롤아웃이 발생해 504** 가 난다. 측정 중에는 HPA 만 만진다.

---

## 옵션

```
--namespace app                 대상 네임스페이스 (기본 app)
--slos-ms user=200,stress=1000  앱별 성능 SLO(ms). 미지정 시 Deployment의 `*/slo-ms` annotation →
                                컨테이너 `SLO_MS` env → `APP_SLOS_MS` env → 기본 200ms 순으로 결정
--since 15m                     조회 기간 (5m/15m/30m/1h) — monitor.py 만
--once / --watch <초>           터미널 1회 / 주기 갱신 — monitor.py 만
--port 8080                     웹서버 포트
--host 127.0.0.1                바인딩 주소. 기본 로컬만
--waf-log-group / --waf-region  기본 aws-waf-logs-wsi2026 / us-east-1
--demo                          샘플 데이터로 레이아웃 확인 — dashboard.py 만
```

**`--host` 는 기본 `127.0.0.1`** 이다. 이 대시보드에는 인증이 없어서 `0.0.0.0` 으로 열면 같은
네트워크의 누구나 클러스터 정보를 볼 수 있다. 터널(`tunnel.sh`)은 localhost 로 접속하므로
기본값 그대로 동작한다.

⚠ WAF 는 CloudFront scope 이므로 **로그는 반드시 us-east-1**. 프로젝트 이름을 바꿨으면
로그그룹도 `aws-waf-logs-<project>` 로 지정한다.

---

## 데이터가 비어 보일 때

**WAF 탭이 "로깅 미설정"**
terraform `waf.tf` 에 로깅이 있어야 찬다(로그그룹 `aws-waf-logs-*` +
`aws_wafv2_web_acl_logging_configuration`). 로그그룹 이름이 다르면 `--waf-log-group` 으로 지정.

**앱 탭 요청 통계가 0**
앱이 JSON 액세스 로그를 stdout 으로 찍어야 파싱된다. 형식 확인:

```bash
kubectl -n app logs deploy/user --tail=3
```

파서는 `status`/`code`, `path`/`uri`, `dur_ms`/`latency_ms` 등 대체 키도 시도한다.
JSON 이 아니면 카운트가 안 잡히니 앱 로그 형식을 먼저 본다.

**CPU/MEM 이 `-`**
metrics-server 미설치/미준비. `kubectl -n kube-system get deploy metrics-server`

---

## 관련 도구

부하 측정·자동 튜닝·응답규약 검증은 [`../tuning/`](../tuning/README.md).

| 하고 싶은 것 | 도구 |
|---|---|
| 지금 상태·원인 보기 | `tools/` (이 폴더) |
| 채점처럼 재보기 | `tuning/loadtest.ps1` |
| 403/404/이미지 규약 확인 | `tuning/verify.ps1` |
| cpu/HPA 값 탐색 | `tuning/autotune.ps1` |
| 안 막힌 공격 패턴 찾기 | `tuning/waf_header_stats.py` → 이 대시보드 `WAF분석` 탭에 붙여넣기 |
