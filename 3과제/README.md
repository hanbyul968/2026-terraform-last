# 2026 전국기능경기대회 클라우드컴퓨팅 — 3과제 (System Operation)

앱 3개(user/product/stress)를 EKS에 배포하고 CloudFront 단일 엔드포인트로 트래픽을 받으며,
**가용성·성능을 지키면서 최소 비용으로 운영**하는 과제. 경기 3시간, 트래픽은 **시작 1시간 뒤** 주입.

> 대회장에서는 아래 **대회날 순서**를 위에서부터 그대로 실행한다.
> 환경/아키텍처/설계 설명은 문서 아래쪽 참고용이다.

---

## 대회날 순서 (이대로 실행)

시간은 목표치. 명령은 전부 `3과제\` 아래에서 실행한다.

| 시각 | 할 일 | 명령 / 링크 |
|---|---|---|
| 0:00 | **배포** (최초는 2단계 병렬) | [terraform/README "2. 배포"](terraform/README.md#2-배포) |
| ~0:20 | 받은 **바이너리 교체** → apply | [terraform/README "3. 바이너리 교체"](terraform/README.md#3-바이너리-교체) |
| ~0:25 | 스펙 바뀌었으면 대응 | 아래 [스펙 바뀌면](#스펙-바뀌면) |
| ~0:35 | **응답규약 검증 → 엔드포인트 제출** | `cd tuning ; .\verify.ps1` |
| ~0:37 | **baseline 측정** (~3분) | `.\loadtest.ps1 -Duration 120s -Label t1` |
| ~0:40~0:58 | **라이브 자동 최적화** (18분 상한, warmup 60s + baseline/candidate 각 120s, 후보 최대 3개) | `.\optimize.ps1 -Apply` |
| 1:00~ | 트래픽 시작. **모니터링 + WAF 추가 차단** | `cd tools ; .\dashboard.ps1` |
| 종료 | 부하 중지 / (연습계정) destroy | `terraform destroy -auto-approve` |

> ⏱ **트래픽 전 1시간 = `terraform apply`(~30분) + 튜닝(~20분).** 튜닝은 워밍업 후 120초 측정 + 18분
> 예산의 `optimize.ps1`로 끝낸다. 측정이 너무 짧으면 콜드스타트가 섞여 user perf 가 실제(80%+)보다 낮게 찍힌다.

**0:00 환경이 처음이면** 먼저 아래 [처음 세팅](#처음-세팅-새-pc--새-계정)을 1회 끝내고 배포로 온다.

### 절대 규칙 3가지

1. **avail% 99% 사수.** 가용성 > 성능 > 비용. avail이 깨지면 성능 점수도 같이 죽는다.
2. **트래픽 중 `terraform apply`/`requests` 변경 금지.** 파드 롤아웃이 그대로 504가 된다. 부하 중엔 HPA만 만진다.
3. **한 번에 한 앱만** 바꾸고 재측정. 동시에 여러 개 바꾸면 원인을 못 찾는다.

---

## ~0:35 — 응답규약 검증 후 엔드포인트 제출

```powershell
cd tuning
.\verify.ps1                    # 정상 2xx / 유효경로 공격 403 / 미정의 404 / 이미지 200
```

FAIL이면 원인별 처방이 같이 나온다. **여기서 실패하면 다른 것보다 먼저 고친다.**
통과하면 `terraform output -raw endpoint` 값을 채점 플랫폼에 제출한다.

> ⚠ 제출 형식: **프로토콜 + 도메인만** (`https://도메인`). 경로(`/v1/` 등)를 붙이면 오답.

---

## 트래픽 전 — 측정하고 값을 확정한다

```powershell
.\loadtest.ps1 -Duration 120s -Label t1     # 측정 + 채점 환산 + 앱별 권장값 자동 출력 (~3분)
```

리포트의 **채점 환산**(가용성/성능/비용)에서 어디서 점수가 새는지 바로 보인다.
대시보드 계산/튜닝 탭, `advise.py`, `optimize.py`, `score.py`는 모두 `tuning/tuning_engine.py`와
`tuning/rubric.py`를 사용한다. 따라서 후보 순서·공식 36점 소계·안전 게이트·적용/롤백 명령이 같다.
튜닝 중 source of truth는 **라이브 Deployment/HPA**이며 Terraform과의 drift는 의도된 상태다.

- **자동 탐색(권장)**: `.\optimize.ps1 -Apply` — warmup 60초, baseline 120초 후 최대 3개 후보를
  각각 120초 실측한다. 기본 목표는 **비용 우선**이며 유지선은 **가용성 ≥90% · 성능 ≥80%**다
  (공식 채점상 가용성 90%면 앱당 만점, 성능 30% 미만이면 비용 12점이 0). 성능을 우선하려면
  `-Objective balanced`. request는 파드당 실사용의 절반이 하한이고 한 회차에 절반까지만 내린다.
  여러 앱은 한 회차에 함께 적용해 예산을 아낀다.
  request/HPA를 트랜잭션으로 적용하고 실패·중단 시 마지막 우승 snapshot으로
  되돌리며, 18분 안에 롤백 시간까지 예약하고 종료한다. **튜닝 흐름에 Terraform apply는 필요 없다.**
- **수동 1-step**: 대시보드 계산/튜닝 탭 또는 `advise.py`의 후보에서 `적용` 명령을 실행하고
  120초 재측정한다. 개선되지 않으면 후보에 같이 표시된 **정확한 롤백 명령**을 그대로 실행한다.
  request 변경은 Deployment rollout을 일으키므로 공식 트래픽 전에만 실행한다.

자세한 사용법·주의는 [tuning/README](tuning/README.md).

---

## 1:00~ — 트래픽 중 운영

**상태 보기**
```powershell
cd tools
.\dashboard.ps1                 # 로컬 웹 UI: 공식 avail/perf, Pod/node/WAF, 공통 엔진 후보
# 앱/SLO가 바뀐 날 직접 지정하려면:
py -3 dashboard.py --namespace app --slos-ms checkout=200,search=500,worker=1000
```
Deployment/HPA 이름과 `app` label은 라이브에서 발견한다. SLO는 Deployment의 `*/slo-ms` annotation,
컨테이너 `SLO_MS`, `APP_SLOS_MS` 환경변수, `--slos-ms` 순으로 반영할 수 있다. **계산** 탭에서 공식
36점 소계·실측 CPU 수요·예약 기준 노드 예측·후보를 확인하고, **튜닝적용** 탭의 적용/정확한 롤백 명령을 사용한다.
CloudShell이면 `python3 monitor.py --watch 10` 또는 `bash tunnel.sh`.

**새 공격 차단**
```powershell
python tuning\waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```
"아직 안 막힌 비정상" + tfvars 제안이 나온다. `terraform/terraform.tfvars`에 넣고 apply 후
`.\verify.ps1`로 403/404 유지 확인. ⚠ 리스트 변수는 덮어쓰기라 기본값+새 값을 전부 나열.

---

## 채점 (40점)

| 항목 | 배점 | 측정 대상 | 확인 도구 |
|---|---|---|---|
| 비정상 요청 처리 | 4 | 이미지 다운로드율 + 비정상 요청 403 처리율 | `tuning/verify.ps1` |
| 고가용성·안정성 | 12 | API별 availability (5초 내 2xx) | `tuning/loadtest.ps1` |
| 성능 효율성 | 12 | user·product ≤0.2s, stress ≤1.0s | `tuning/loadtest.ps1` |
| 비용 최적화 | 12 | 인스턴스 비용 ratio (평균 EC2 대수 ÷ 기준 2대, 낮을수록 유리) | `tuning/optimize.ps1` |

> 성능은 비용의 전제조건이다. **세 앱 중 하나라도 perf 30% 미만이면 비용 12점이 통째로 0점**,
> 비용 ratio가 0.5 미만이어도 0점. avail은 ≥90%면 앱당 만점.

---

## 스펙 바뀌면

경로·포트·헬스체크는 **terraform 변수 하나**로 ALB·WAF·CloudFront·k8s 전 계층에 반영된다.

| 바뀐 것 | 변수 |
|---|---|
| API prefix (`/v1`→`/v2`) | `api_prefix` (경로가 앱 이름과 다르면 `api_paths_override`) |
| 헬스체크 경로 | `healthcheck_path` |
| 컨테이너 포트 | `container_port` |
| 이미지 경로 | `images_prefix` |
| 새 WAF 차단 패턴 | `waf_blocked_user_agents` / `waf_blocked_headers` / `waf_blocked_body_patterns` 등 |

⚠ terraform 변수를 바꿔도 **`tuning/config.ps1`**의 `$APIS`·`$HC_PATH`·`$IMAGES_PREFIX`는 자동
반영되지 않는다. 부하·검증 도구가 옛 경로를 때리지 않게 같이 고친다. 앱 추가·DB 스키마 변경 등
파일을 고쳐야 하는 경우는 [terraform/README "API/스펙 변경 대응"](terraform/README.md#4-apispec-변경-대응).

---

## 폴더

| 폴더 | 역할 |
|---|---|
| [`terraform/`](terraform/README.md) | **인프라 전체**. VPC·EKS·RDS·S3·ALB·CloudFront·WAF, apply로 배포 |
| [`tuning/`](tuning/README.md) | **측정·검증·튜닝**. verify / loadtest / optimize / autotune / WAF 분석 |
| [`tools/`](tools/README.md) | **모니터링 대시보드**. 상태와 원인 진단을 한 화면에 |
| [`application/binary/`](application/binary) | 배포용 바이너리 + Dockerfile. 대회날 여기만 덮어쓴다 |
| `load_user.dump` | DB 시드 덤프 (terraform이 S3 경유로 자동 적재) |

---

## 아키텍처

```
인터넷 → CloudFront (단일 엔드포인트, WAFv2)
           ├─ /images/*   → S3 (OAC, 캐싱)
           ├─ /v1/product → ALB (id 쿼리 기준 캐싱)
           └─ 그 외       → ALB → EKS Pod (user/product/stress)
                             └ 미정의 경로 → 404 / CloudFront 우회 → 403

Pod → RDS Proxy (커넥션 풀러) → RDS MySQL 8.0 Multi-AZ (db.t3.micro)
노드: t3.medium (관리형 NG 2대 + Karpenter 증설/회수)
```

- **비정상 요청**: 유효 경로의 공격 = WAF 403 / 없는 경로(`/.env` 등) = ALB 404
- **성능**: product GET CloudFront 캐싱, `/images/*` S3 캐싱, `user.email` 인덱스
- **비용**: NAT 없음, t3.medium 최소 대수 + Karpenter consolidation

설계 근거와 상세는 [terraform/README](terraform/README.md#1-아키텍처).

---

## 처음 세팅 (새 PC / 새 계정)

**아무것도 설치되지 않은 Windows + 빈 AWS 계정** 기준. 이미 세팅된 PC면 건너뛴다.

**1) 패키지 설치** — 관리자 PowerShell:
```powershell
$pkgs = 'Hashicorp.Terraform','Amazon.AWSCLI','Kubernetes.kubectl',
        'Docker.DockerDesktop','Python.Python.3.13','Git.Git','Helm.Helm'
foreach ($p in $pkgs) { winget install --exact --id $p --accept-source-agreements --accept-package-agreements }
python -m pip install --upgrade pip; python -m pip install boto3 flask   # boto3=WAF분석, flask=대시보드
```
설치 후 **새 창**을 열어야 PATH 반영. **Docker Desktop은 실행해 엔진을 띄워 둔다**(안 하면 apply가 build에서 멈춤).

**2) 설치 확인**:
```powershell
foreach ($c in 'terraform','aws','kubectl','docker','python','git') {
  '{0,-11} {1}' -f $c, $(if (Get-Command $c -EA SilentlyContinue) {'설치됨'} else {'없음 ←'})
}
```
검증 조합: terraform 1.13.4 / aws-cli 2.34.62 / kubectl 1.34.0 / docker 29.5.2 / python 3.13.3.

**3) 자격증명** (리전 `ap-northeast-2` 고정, 관리자 권한 계정):
```powershell
aws configure          # region: ap-northeast-2
aws sts get-caller-identity
```

**4) clone** (바이너리·DB 덤프 포함, 따로 받을 것 없음):
```powershell
git clone https://github.com/hnmly/2026-terraform.git C:\wsi
cd C:\wsi\3과제\terraform
```

**5) 버킷 이름(신규 계정 필수)** — S3 이름은 전역 고유. `terraform.tfvars` 맨 위에:
```hcl
bucket_prefix = "wsi2026-608"   # 608=본인 비번호, 전역 유일값
```

**6) 배포** — `terraform init` 후 [terraform/README "2. 배포"](terraform/README.md#2-배포)의 2단계 명령.
끝나면 `terraform output endpoint`를 제출.

### 신규 계정에서 실제로 걸리는 것

| 증상 | 원인 / 대응 |
|---|---|
| `BucketAlreadyExists` | 위 5번 `bucket_prefix` 미설정 |
| build 단계에서 멈춤 | Docker Desktop 미실행 |
| `VcpuLimitExceeded` | vCPU 쿼터. Service Quotas → EC2 → Running On-Demand Standard 증설 (t3.medium 8대=16 vCPU) |
| `AccessDenied` on `iam:CreateServiceLinkedRole` | 관리자 권한 아님 |
| CloudFront `InProgress` 지속 | 정상, 전파 15~20분 |
| `Error acquiring the state lock` | 이전 apply 중단. `terraform` 프로세스 종료 대기 |

state는 로컬 `terraform/terraform.tfstate`에 저장되고 git에 안 올라간다 → **다른 PC에서 이어받지 않고 새로 배포**.
같은 계정에 배포 흔적이 있는데 state가 없으면 이름 충돌 → 연습계정은 `terraform destroy`로 정리하거나
`bucket_prefix`/`-var project=`를 바꾼다.
