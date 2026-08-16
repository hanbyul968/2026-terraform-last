# 2026 전국기능경기대회 클라우드컴퓨팅 — 3과제 (System Operation)

앱 3개(user/product/stress)를 EKS에 배포하고 CloudFront 단일 엔드포인트로 트래픽을 받으며,
**가용성·성능을 지키면서 최소 비용으로 운영**하는 과제. 경기 3시간, 트래픽은 **시작 1시간 뒤** 주입.

> 이 문서가 시작점. 대회날 헷갈리면 여기부터 본다.

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

Pod → ProxySQL (커넥션 풀러) → RDS MySQL 8.0 Multi-AZ (db.t3.micro)
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
