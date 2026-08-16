# 2026 전국기능경기대회 클라우드컴퓨팅 — 3과제 (System Operation)

앱 3개(user/product/stress)를 EKS에 배포하고 CloudFront 단일 엔드포인트로 트래픽을 받으며,
**가용성·성능을 지키면서 최소 비용으로 운영**하는 과제. 경기 3시간, 트래픽은 **시작 1시간 뒤** 주입.

> 이 문서가 시작점. 대회날 헷갈리면 여기부터 본다.

---

## 새 PC · 새 계정에서 처음 시작하기

**아무것도 설치되지 않은 Windows PC + 비어 있는 새 AWS 계정** 기준. 위에서부터 그대로 따라간다.
이미 세팅된 PC면 이 절을 건너뛰고 [배포](terraform/README.md#2-배포)로 간다.

### 1. 필수 패키지 설치 (PowerShell)

**관리자 권한 PowerShell**에서 실행한다. winget은 Windows 10 1809 이상에 기본 포함이다.

```powershell
$pkgs = @(
  'Hashicorp.Terraform',   # 인프라 배포 (필수)
  'Amazon.AWSCLI',         # ECR 로그인, kubeconfig, 지표 조회 (필수)
  'Kubernetes.kubectl',    # 파드/HPA 확인, 튜닝 (필수)
  'Docker.DockerDesktop',  # 이미지 빌드/push (필수)
  'Python.Python.3.13',    # 측정·대시보드 스크립트 (필수)
  'Git.Git',               # 리포 clone (필수)
  'Helm.Helm'              # 선택: helm history 등 트러블슈팅용
)
foreach ($p in $pkgs) {
  winget install --exact --id $p --accept-source-agreements --accept-package-agreements
}
```

설치 후 **PowerShell 창을 새로 열어야** PATH가 반영된다.
`Docker Desktop`은 한 번 실행해서 **엔진이 떠 있는 상태로 둔다** (안 띄우면 apply가 build 단계에서 멈춘다).

파이썬 외부 패키지는 두 개뿐이다 (나머지는 표준 라이브러리).

```powershell
python -m pip install --upgrade pip
python -m pip install boto3 flask
```

| 패키지 | 쓰는 곳 |
|---|---|
| `boto3` | `tuning/waf_header_stats.py` (WAF 로그 조회) |
| `flask` | `tools/dashboard.py` (모니터링 웹 UI) |

`tools/monitor.py`·`tuning/score.py`·`tuning/advise.py`는 표준 라이브러리 + `aws`/`kubectl` CLI만 쓴다.

### 2. 설치 확인

```powershell
foreach ($c in 'terraform','aws','kubectl','docker','python','git') {
  '{0,-11} {1}' -f $c, $(if (Get-Command $c -EA SilentlyContinue) { '설치됨' } else { '없음 ←' })
}
docker info --format '{{.ServerVersion}}' 2>$null | ForEach-Object { "docker engine $_" }
python -c "import boto3, flask; print('boto3 / flask OK')"
```

`없음 ←` 이나 `docker engine` 줄이 안 나오면 다음으로 넘어가지 않는다.
검증된 조합: terraform 1.13.4 / aws-cli 2.34.62 / kubectl 1.34.0 / docker 29.5.2 / python 3.13.3.

### 3. AWS 자격증명

새 계정에서 발급받은 액세스 키로 설정한다. 리전은 **`ap-northeast-2`** 고정.

```powershell
aws configure
# AWS Access Key ID     : <발급받은 키>
# AWS Secret Access Key : <발급받은 시크릿>
# Default region name   : ap-northeast-2
# Default output format  : json

aws sts get-caller-identity      # 계정 ID가 나오면 성공
```

관리자 권한 계정이어야 한다 (EKS·RDS·CloudFront·WAF·IAM 생성 필요).
프로파일을 여러 개 쓰면 모든 apply에 `-var aws_profile=<이름>`을 붙인다.

### 4. 리포 clone

```powershell
git clone https://github.com/hnmly/2026-terraform.git C:\wsi
cd C:\wsi\3과제\terraform
```

배포에 필요한 **바이너리와 DB 덤프가 리포에 포함**되어 있어(`application/binary/{user,product,stress}`,
`load_user.dump`) clone만으로 배포가 가능하다. 따로 받을 파일은 없다.

### 5. 계정 고유값 설정 — 버킷 이름 (신규 계정에서 반드시)

S3 버킷 이름은 **AWS 전체에서 전역 고유**하다. 기본값 `wsi2026-images` / `wsi2026-artifacts`는
다른(이전) 계정이 이미 쓰고 있으면 `BucketAlreadyExists`로 apply가 실패한다.

`terraform.tfvars` (지금 디렉터리에 이미 있다) 맨 위에 한 줄 추가한다.
한 번 넣으면 이후 모든 apply에 계속 적용된다.

```hcl
bucket_prefix = "wsi2026-608"   # 608 = 본인 비번호. 전역에서 겹치지 않는 값
```

> `-var bucket_prefix=...` 로 줘도 되지만, **매 apply마다 빠짐없이** 붙여야 해서
> tfvars에 박아두는 쪽이 안전하다. 빠뜨리면 이름이 달라져 버킷이 새로 만들어진다.

### 6. 배포

`3과제\terraform` 에서:

```powershell
terraform init
```

이후 최초 구축은 provider 의존성 때문에 **2단계**다 (클러스터 → 나머지 전체).
그대로 복사해 쓸 명령은 [terraform/README "2. 배포"](terraform/README.md#2-배포)에 있다.
끝나면 `terraform output endpoint` 값을 채점 플랫폼에 제출한다.

### 신규 계정에서 실제로 걸리는 것

| 증상 | 원인 / 대응 |
|---|---|
| `BucketAlreadyExists` | 위 5번의 `bucket_prefix` 미설정 |
| build 단계에서 멈춤 / `docker: command not found` | Docker Desktop 미실행. 트레이 아이콘 확인 |
| `VcpuLimitExceeded` | 신규 계정 vCPU 쿼터. t3.medium 최대 8대 = 16 vCPU 필요.<br>Service Quotas → EC2 → *Running On-Demand Standard instances* 증설 요청 |
| `AccessDenied` on `iam:CreateServiceLinkedRole` | 관리자 권한 아님. EKS/ELB/RDS가 서비스 연결 역할을 만들어야 한다 |
| CloudFront가 한참 `InProgress` | 정상. 배포 전파에 15~20분 걸린다 |
| `Error acquiring the state lock` | 이전 apply가 중단됨. `terraform` 프로세스가 끝날 때까지 기다린다 |

state는 **로컬 `terraform/terraform.tfstate`** 에 저장되고 git에 올라가지 않는다.
따라서 **다른 PC에서 이어받는 게 아니라 처음부터 새로 배포**하는 흐름이다.
같은 계정에 이미 배포된 스택이 있는데 state가 없으면 이름 충돌이 나므로,
연습 계정이면 먼저 `terraform destroy` 로 정리하거나 위 `bucket_prefix`/`-var project=` 를 바꾼다.

---

## 폴더

| 폴더 | 역할 |
|---|---|
| [`terraform/`](terraform/README.md) | **인프라 전체**. VPC·EKS·RDS·S3·ALB·CloudFront·WAF, apply 한 번으로 배포 |
| [`application/binary/`](application/binary) | 배포에 쓰는 **바이너리**(user/product/stress) + Dockerfile. 대회날 여기만 덮어쓴다 |
| [`tuning/`](tuning/README.md) | **측정·검증·튜닝 CLI**. 응답규약 검증(verify), 부하 측정(loadtest), 자동 스윕(autotune), WAF 로그 분석 |
| [`tools/`](tools/README.md) | **모니터링 대시보드**. 지금 상태(가용성/성능/pod/node/WAF)와 원인 진단을 한 화면에 |
| [`../부하/`](../부하/README.md) | 수동 부하 GUI (점수 눈으로 확인) + 노드 강제 스케일용 고부하 |
| `load_user.dump` | DB 시드 덤프 (terraform이 S3 경유로 자동 적재) |

---

## 채점 (40점)

| 항목 | 배점 | 측정 대상 | 확인 도구 |
|---|---|---|---|
| 비정상 요청 처리 | 4 | 이미지 다운로드율 + 비정상 요청 403 처리율 | `tuning/verify.ps1` |
| 고가용성·안정성 | 12 | API별 availability (5초 내 2xx) | `tuning/loadtest.ps1` |
| 성능 효율성 | 12 | user·product ≤0.2s, stress ≤1.0s | `tuning/loadtest.ps1` |
| 비용 최적화 | 12 | 인스턴스 비용 ratio (0.5~, 낮을수록 유리) | `tuning/autotune.ps1` |

**우선순위: 가용성 > 성능 > 비용.** avail%를 깨면서 비용을 줄이면 성능 점수까지 같이 무너진다.

---

## 아키텍처

```
인터넷 → CloudFront (단일 엔드포인트, WAFv2)
           ├─ /images/*   → S3 (OAC, 캐싱)
           ├─ /v1/product → ALB (id 쿼리 기준 캐싱)
           └─ 그 외       → ALB → EKS Pod (user/product/stress)
                             └ 미정의 경로 → 404 / CloudFront 우회 → 403

Pod → RDS Proxy (커넥션 풀러) → RDS MySQL 8.0 Multi-AZ (db.t3.micro)
노드: t3.medium (관리형 NG + Karpenter)
```

- **비정상 요청**: 유효 경로의 공격 = WAF 403 / 없는 경로(`/.env` 등) = ALB 404
- **성능**: product GET CloudFront 캐싱, `/images/*` S3 캐싱, `user.email` 인덱스
- **비용**: NAT 없음, t3.medium 최소 대수 + Karpenter consolidation

설계 근거와 상세는 [terraform/README](terraform/README.md#1-아키텍처).

---

## 대회날 순서

| 시각 | 할 일 | 문서 |
|---|---|---|
| 0:00 | 배포 (최초는 2단계) | [terraform/README](terraform/README.md#2-배포) |
| ~0:20 | 받은 바이너리 교체 → apply | [terraform/README](terraform/README.md#3-바이너리-교체) |
| ~0:25 | 스펙이 바뀌었으면 대응 | [terraform/README](terraform/README.md#4-apispec-변경-대응) |
| ~0:35 | **응답규약 검증** → 엔드포인트 제출 | `cd tuning ; .\verify.ps1` |
| ~0:45 | 부하도구 준비 + baseline 측정 | [tuning/README](tuning/README.md) |
| 트래픽 전 | 병목 앱 튜닝값 확정 → `k8s_apps.tf` 반영 | [tuning/README](tuning/README.md) |
| 1:00~ | 모니터링 + WAF 추가 차단 반복 | [tools/README](tools/README.md) |
| 종료 | 부하 중지 / (연습계정) destroy | `terraform destroy -auto-approve` |

배포 명령은 [terraform/README](terraform/README.md#2-배포)에 있다. 최초 구축은 provider 의존성 때문에
2단계이고, `-target` 을 쓸 때 PowerShell 에서는 `--%` 가 필요하다.

---

## 언제 뭘 쓰나

### 배포 직후 — 응답규약 4점 확보

```powershell
cd tuning
.\verify.ps1
```

정상 2xx / 유효경로+비정상 403 / 미정의경로 404 / 이미지 다운로드 200 을 한 번에 확인한다.
FAIL 이면 원인별 처방까지 출력한다. **여기서 실패하면 다른 것보다 먼저 고친다.**

### 트래픽 전 — 측정하고 값 확정

```powershell
.\loadtest.ps1 -Duration 180s -Label baseline    # 측정 + 앱별 권장값 자동 출력
.\autotune.ps1 -App stress -Duration 90s          # 병목 앱만 조합 스윕
```

나온 값을 `terraform/k8s_apps.tf` 의 해당 앱 `requests.cpu` / HPA `average_utilization`·`min_replicas`
에 박고 apply. `kubectl patch` 는 재배포 시 사라진다.

### 트래픽 중 — 상태 보기

```powershell
cd tools
.\dashboard.ps1                                   # 로컬 웹 UI
```

CloudShell 이면 `python3 monitor.py --watch 10` (터미널) 또는 `bash tunnel.sh` (웹 UI).
avail%/perf%/pod/node/WAF 와 5xx·4xx 원인 진단을 한 화면에서 본다.

### 트래픽 중 — 새 공격 차단

```powershell
python tuning\waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

"아직 안 막힌 비정상" 과 tfvars 제안이 나온다. `terraform/terraform.tfvars` 에 넣고 apply 후
`.\verify.ps1` 로 403/404 가 유지되는지 재확인. ⚠ 리스트 변수는 덮어쓰기라 기본값+새 값을 전부 나열.

---

## 스펙이 바뀌면

경로·포트·헬스체크는 **terraform 변수 하나**로 ALB·WAF·CloudFront·k8s 전 계층에 반영된다.

| 바뀐 것 | 변수 |
|---|---|
| API prefix (`/v1`→`/v2`) | `api_prefix` (경로가 앱 이름과 다르면 `api_paths_override`) |
| 헬스체크 경로 | `healthcheck_path` |
| 컨테이너 포트 | `container_port` |
| 이미지 경로 | `images_prefix` |
| 새 WAF 차단 패턴 | `waf_blocked_user_agents` / `waf_blocked_headers` / `waf_blocked_body_patterns` 등 |

앱 추가·DB 스키마 변경·환경변수 추가처럼 파일을 고쳐야 하는 경우는
[terraform/README "API/스펙 변경 대응"](terraform/README.md#4-apispec-변경-대응)에 파일별로 정리해 뒀다.

⚠ terraform 변수를 바꿔도 **`tuning/config.ps1`** 의 `$APIS`·`$HC_PATH`·`$IMAGES_PREFIX` 는
자동 반영되지 않는다. 부하·검증 도구가 옛 경로를 때리지 않게 같이 고친다.

---

## 핵심 3가지

1. **문제 발견은 `tools/` 대시보드**, 대응은 `tuning/`(성능·비용) 또는 WAF(공격).
2. **한 번에 한 앱만** 바꾸고 재측정. 동시에 여러 개 바꾸면 원인을 못 찾는다.
3. **avail% 99% 사수.** 비용·성능보다 우선이고, 깨지면 성능 점수도 같이 죽는다.
