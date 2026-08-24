# 2026 전국기능경기대회 클라우드컴퓨팅 — 3과제 (System Operation)

앱을 EKS에 배포하고 CloudFront 단일 엔드포인트로 트래픽을 받으며, **가용성·성능을 지키면서 최소 비용으로 운영**하는 과제.
경기 3시간, 트래픽은 **시작 1시간 뒤** 주입.

> **대회날은 아래 순서만 위에서부터 실행한다.** 설계 근거·처음 세팅·트러블슈팅은 [부록](#부록--상세-문서)에 있다.

---

## 대회날 순서

명령은 전부 `3과제\` 아래에서 실행한다.

| 시각 | 할 일 | 명령 |
|---|---|---|
| 0:00 | 배포 | [terraform/README "2. 배포"](terraform/README.md#2-배포) |
| ~0:20 | 받은 **바이너리를 `application/binary/`에 덮어쓰기** → apply | `terraform apply` |
| ~0:25 | 스펙 바뀌었으면 [tfvars 수정](#앱이나-스펙이-바뀌면) |  |
| ~0:35 | 응답규약 검증 → 엔드포인트 제출 | `cd tuning ; .\verify.ps1` |
| ~0:37 | baseline 측정 | `.\loadtest.ps1 -Duration 90s -Label t1` |
| ~0:40 | 튜닝 권장값 산출 (20분 상한) | `.\optimize.ps1` |
| ~0:55 | 값 확인 후 반영 | `.\apply.ps1 -Show` → `terraform apply` |
| 1:00~ | 트래픽 시작. 모니터링 | `cd tools ; .\dashboard.ps1` |
| 종료 | 부하 중지 / (연습계정) destroy | `terraform destroy -auto-approve` |

엔드포인트 제출 형식은 **프로토콜 + 도메인만** (`https://도메인`). 경로를 붙이면 오답.

### 절대 규칙

1. **가용성 > 성능 > 비용.** avail이 깨지면 성능 점수도 같이 죽는다.
2. **트래픽 중 `terraform apply` 금지.** 파드 롤아웃이 그대로 504가 된다. 부하 중 바꿔야 하면 HPA만(`kubectl` 아님 — [아래](#튜닝은-terraform을-거친다) 참고).
3. **한 번에 하나만** 바꾸고 재측정.

---

## 앱이나 스펙이 바뀌면

**`terraform/terraform.tfvars` 한 파일만 고친다.** terraform 코드는 손대지 않는다.

### 앱이 바뀔 때

앱 목록은 `application/binary/`에서 **자동 발견**된다. 바이너리를 덮어쓰면 ECR·이미지 빌드·Deployment·Service·HPA·PDB·ALB 타깃그룹·리스너 룰·WAF 경로·CloudFront 동작이 전부 자동 생성된다.

앱별 특성만 `apps`에 적는다. 안 적으면 `app_defaults`로 뜬다.

```hcl
apps = {
  # 측정으로 알 수 없는 '구조'만 적는다. request/target/replicas 는 튜너가 뽑는다.
  product = { needs_s3 = true, cache_ttl = 10, cache_query_keys = ["id"] }
  stress  = { needs_db = false }
}
```

| 키 | 의미 | 누가 정하나 |
|---|---|---|
| `needs_db` / `needs_s3` | DB 시크릿 / S3 쓰기 IRSA 주입 | **사람** (문제지 보고) |
| `cache_ttl` / `cache_query_keys` | CloudFront GET 캐시 (반복 조회 앱) | **사람** (문제지 보고) |
| `path` / `container_port` / `healthcheck_path` | 앱별 다를 때만 | 사람 |
| `cpu_request_m` / `hpa_target_cpu` / `min·max_replicas` | 파드 CPU·오토스케일 | **튜너** (`optimize.ps1`) |
| `cpu_limit_ratio` | limit = request × 이 값 (기본 0 = 무제한) | 보통 안 건드림 |

**request/target/replicas는 tfvars에 적지 않는다.** 측정 없이는 알 수 없고, 앱이 바뀌면 더더욱 모른다. 튜너가 부하를 넣어 `tuning.auto.tfvars.json`에 뽑아 넣는다(우선순위 `app_tuning > apps > app_defaults`). 튜닝 전 시작값은 `app_defaults`(request 200m, target 50%, 4-12).

**CPU limit은 기본으로 걸지 않는다** (`cpu_limit_ratio = 0`). limit을 걸면 CFS가 100ms 주기마다 쿼터를 끊어 지연 민감 앱의 꼬리지연이 폭증한다 — 실제로 product를 limit 75m로 묶었다가 가용성이 100%→65%로 무너졌다. 이웃 CPU 갈취는 limit이 아니라 request 정상화 + 파드 안티어피니티로 푼다.

### 노드 타입이 바뀔 때

`node_instance_type` 한 줄만 바꾼다. 아래가 자동 재계산된다.

- 노드당 앱 가용 CPU, kubelet `maxPods`(Prefix Delegation 실상한)
- Karpenter 노드 상한(앱 맵의 `max_replicas × request`에서 역산)

아키텍처는 x86_64로 **고정**이다(파생 아님). 문제지가 t3.medium을 강제하고 제공 바이너리가 x86이라 arm으로 바꾸면 실행되지 않으며, `ami_type`을 파생시키면 변수 하나로 노드그룹이 교체되는 위험이 있다. 확인은 `terraform plan`의 `sizing` output.

### 경로·포트가 바뀔 때

| 바뀐 것 | 변수 |
|---|---|
| API prefix (`/v1`→`/v2`) | `api_prefix` (경로가 앱 이름과 다르면 `api_paths_override`) |
| 헬스체크 / 컨테이너 포트 / 이미지 경로 | `healthcheck_path` / `container_port` / `images_prefix` |
| DB 스키마·인덱스 | `db_schema_sql` / `db_required_indexes` |
| WAF 차단 패턴 | `waf_blocked_*` (리스트는 덮어쓰기 — 기본값+새 값 전부 나열) |

⚠ terraform 변수를 바꿔도 **`tuning/config.ps1`**의 `$APIS`·`$HC_PATH`·`$IMAGES_PREFIX`는 자동 반영되지 않는다. 부하·검증 도구가 옛 경로를 때리지 않게 같이 고친다.

---

## 튜닝은 Terraform을 거친다

`tuning/`은 클러스터를 `kubectl`로 직접 고치지 않는다. 권장값을 `terraform/tuning.auto.tfvars.json`에 기록하고, 반영은 `terraform apply`가 한다.

```powershell
.\optimize.ps1                       # 측정 + 권장값 기록 (클러스터 안 건드림, 20분 상한)
.\apply.ps1 -Show                    # 기록된 값 확인
.\apply.ps1 -App user -Request 120   # 값만 기록
.\rollback.ps1                       # 튜닝 전부 제거 → apps 값 복귀
```

반영까지 한 번에 하려면 `-RunTerraform`을 붙인다.

**`kubectl patch`로 직접 고치면 안 되는 이유:** 라이브 상태가 Terraform state와 어긋나(드리프트) 무엇이 채점된 구성인지 알 수 없게 되고, 누군가 `terraform apply`를 하는 순간 튜닝이 조용히 원복된다. 실제로 채점 회차에서 라이브 값이 `.tf` 파일값과 전부 달랐던 적이 있다.

변수 역할이 나뉘어 있다. `apps`는 사람이 쓰는 **구조**(경로·needs_s3·cache_ttl), `app_tuning`은 툴이 쓰는 **수치**(request·target·replicas). 우선순위는 `app_tuning > apps > app_defaults`이고, 툴은 `app_tuning`만 건드리므로 구조 설정이 지워지지 않는다.

> ⚠ `tools/dashboard.py`의 "튜닝적용" 탭은 아직 `kubectl` 명령을 낸다. 그걸 쓰면 드리프트가 재발한다.

---

## 채점 (40점)

| 항목 | 배점 | 측정 대상 | 도구 |
|---|---|---|---|
| 비정상 요청 처리 | 4 | 이미지 다운로드율 + 비정상 요청 403 처리율 | `tuning/verify.ps1` |
| 고가용성·안정성 | 12 | API별 availability (5초 내 2xx) | `tuning/loadtest.ps1` |
| 성능 효율성 | 12 | user·product ≤0.2s, stress ≤1.0s | `tuning/loadtest.ps1` |
| 비용 최적화 | 12 | 인스턴스 비용 ratio (평균 EC2 대수 ÷ 기준 대수) | `tuning/optimize.ps1` |

**성능은 비용의 전제조건이다.** 채점표 4-1~4-12는 전부 "모든 앱 성능 ≥ 30%"를 함께 요구한다. 한 앱이라도 30% 미만이면 **비용 12점이 통째로 0**이 된다. ratio가 0.5 미만이어도 0점. avail은 ≥90%면 앱당 만점.

> 비용 ratio의 **분모(기준 대수)는 공개되지 않는다.** "노드 N대 = M점" 환산은 추정일 뿐이다. 확실한 것은 (1) 30% 게이트가 실재한다 (2) 노드가 적을수록 유리하다 — 방향뿐이다.

---

## 아키텍처

```
인터넷 → CloudFront (단일 엔드포인트, WAFv2)
           ├─ /images/*      → S3 (OAC, 캐싱)
           ├─ 캐시 대상 앱   → ALB (쿼리 기준 캐싱, apps.cache_ttl)
           └─ 그 외          → ALB → EKS Pod
                                └ 미정의 경로 → 404 / CloudFront 우회 → 403

Pod → RDS Proxy → RDS MySQL 8.0 Multi-AZ (db.t3.micro)
노드: 관리형 NG(고정 2대) + Karpenter(부하 시 증설, 종료 후 회수)
```

**비정상 요청** — 유효 경로의 공격은 WAF 403, 없는 경로는 ALB 404.

**성능** — 지연 민감 앱이 CPU를 빼앗기지 않게 두 가지가 자동으로 걸린다. 앱 이름을 몰라도 동작한다.

1. **CPU limit = request × 1.5.** 크게 burst하는 파드가 같은 노드 이웃의 CPU를 가져가는 것을 막는다. cgroup CPU는 비율 분배라 burst하는 쪽이 항상 이긴다. 실제로 limit/request가 3배인 앱 때문에 지연 민감 앱의 p50이 27ms → 330ms로 무너진 적이 있다.
2. **서로 다른 앱은 같은 노드를 피한다** (pod anti-affinity, 선호). 유휴에는 노드가 적어 같이 앉고, 부하로 파드·노드가 늘면 앱마다 다른 노드로 분리된다.

**비용** — NAT 없음. 유휴 노드 수는 `min_replicas × request`가 결정하고, Karpenter가 부하 종료 3분 후 통합·회수한다.

---
---

# 부록 — 상세 문서

> 아래는 기존 문서다. 위 내용과 겹치는 부분은 위쪽이 최신이다.

## 폴더

| 폴더 | 역할 |
|---|---|
| [`terraform/`](terraform/README.md) | **인프라 전체**. VPC·EKS·RDS·S3·ALB·CloudFront·WAF, apply로 배포 |
| [`tuning/`](tuning/README.md) | **측정·검증·튜닝**. verify / loadtest / optimize / autotune / WAF 분석 |
| [`tools/`](tools/README.md) | **모니터링 대시보드**. 상태와 원인 진단을 한 화면에 |
| [`application/binary/`](application/binary) | 배포용 바이너리 + Dockerfile. 대회날 여기만 덮어쓴다 |
| `load_user.dump` | DB 시드 덤프 (terraform이 S3 경유로 자동 적재) |

## ~0:35 — 응답규약 검증 후 엔드포인트 제출

```powershell
cd tuning
.\verify.ps1                    # 정상 2xx / 유효경로 공격 403 / 미정의 404 / 이미지 200
```

FAIL이면 원인별 처방이 같이 나온다. **여기서 실패하면 다른 것보다 먼저 고친다.**
통과하면 `terraform output -raw endpoint` 값을 채점 플랫폼에 제출한다.

## 트래픽 전 — 측정하고 값을 확정한다

```powershell
.\loadtest.ps1 -Duration 90s -Label t1     # 측정 + 채점 환산 + 앱별 권장값 자동 출력
```

리포트의 **채점 환산**(가용성/성능/비용)에서 어디서 점수가 새는지 바로 보인다.
대시보드 계산/튜닝 탭, `advise.py`, `optimize.py`, `score.py`는 모두 `tuning/tuning_engine.py`와
`tuning/rubric.py`를 사용한다. 따라서 후보 순서·공식 36점 소계·안전 게이트가 같다.

- **자동 탐색(권장)**: `.\optimize.ps1` — warmup 30초, baseline 90초 후 전 앱 묶음 후보를 실측한다.
  기본 목표는 **비용 우선**이며 유지선은 **가용성 ≥90% · 성능 ≥80%**다. 성능을 우선하려면
  `-Objective balanced`. request는 **부하량으로 정규화**해 계산한다:
  `요청당 CPU × 목표 rps ÷ 파드수`. 측정 부하가 채점 부하보다 세면 `-LoadScale 0.5`처럼 낮추거나
  `-TargetRps user=100,stress=10`으로 rps를 고정한다. 하한은 파드당 필요 CPU의 절반이고
  한 회차에 현재값의 절반까지만 내린다. 각 단계 앞에서 남은 예산을 확인해 20분을 넘기지 않는다.
- **수동 1-step**: `advise.py`의 후보에서 값을 확인하고 `apply.ps1`로 기록한 뒤 재측정한다.
  개선되지 않으면 `rollback.ps1`로 되돌린다.
  request 변경은 Deployment rollout을 일으키므로 공식 트래픽 전에만 실행한다.

자세한 사용법·주의는 [tuning/README](tuning/README.md).

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
36점 소계·실측 CPU 수요·예약 기준 노드 예측·후보를 확인한다.
CloudShell이면 `python3 monitor.py --watch 10` 또는 `bash tunnel.sh`.

**새 공격 차단**
```powershell
python tuning\waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```
"아직 안 막힌 비정상" + tfvars 제안이 나온다. `terraform/terraform.tfvars`에 넣고 apply 후
`.\verify.ps1`로 403/404 유지 확인. ⚠ 리스트 변수는 덮어쓰기라 기본값+새 값을 전부 나열.

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
| `VcpuLimitExceeded` | vCPU 쿼터. Service Quotas → EC2 → Running On-Demand Standard 증설 |
| `AccessDenied` on `iam:CreateServiceLinkedRole` | 관리자 권한 아님 |
| CloudFront `InProgress` 지속 | 정상, 전파 15~20분 |
| `Error acquiring the state lock` | 이전 apply 중단. `terraform` 프로세스 종료 대기 |
| `Invalid start of value` on tfvars | JSON에 BOM. `tuning.auto.tfvars.json`을 BOM 없이 다시 쓴다 |
| Karpenter `no subnets found` | 서브넷 `karpenter.sh/discovery` 태그 확인. apply 직후면 일시적 |
| 노드가 안 빠짐 | 파드가 남은 노드는 `WhenEmptyOrUnderutilized` + 3분 대기 후 회수. preferred topology spread가 통합을 막을 수 있다 |

state는 로컬 `terraform/terraform.tfstate`에 저장되고 git에 안 올라간다 → **다른 PC에서 이어받지 않고 새로 배포**.
같은 계정에 배포 흔적이 있는데 state가 없으면 이름 충돌 → 연습계정은 `terraform destroy`로 정리하거나
`bucket_prefix`/`-var project=`를 바꾼다.
