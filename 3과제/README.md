# 2026 전국기능경기대회 클라우드컴퓨팅 — 3과제 (System Operation)

개발된 3개 앱(user/product/stress)을 EKS에 배포하고, CloudFront 단일 엔드포인트로 트래픽을
받으며, **목표 서비스 수준(가용성·성능)을 지키면서 최소 비용으로 운영**하는 과제.
경기 3시간, 트래픽은 **시작 1시간 뒤** 채점 플랫폼에서 주입됨.

> **이 문서 = 시작점.** 폴더별 상세는 각 하위 README 링크로. 대회날 헷갈리면 여기부터 본다.

---

## 📁 폴더 지도

| 폴더 | 역할 | 상세 |
|---|---|---|
| [`terraform/`](terraform/README.md) | **인프라 전체** (VPC·EKS·RDS·S3·ALB·CloudFront·WAF). apply 한 번으로 배포 | [README](terraform/README.md) |
| [`application/`](application) | 3개 Go 앱 소스 + **배포에 쓰는 바이너리**(`binary/{user,product,stress}`) | — |
| [`tools/`](tools/README.md) | **모니터링 대시보드** — 지금 상태(가용성/성능/pod/node/WAF)를 한 화면에 | [README](tools/README.md) |
| [`tuning/`](tuning/README.md) | **자동 튜닝 CLI** — 부하→측정→앱별 권장값(advise)→자동 스윕(autotune) + WAF 로그 분석 | [README](tuning/README.md) |
| [`logcheck/`](logcheck/README.md) | 용량 프로파일링(k6) — 예상 트래픽 → 권장 파드/노드 (tuning의 대안) | [README](logcheck/README.md) |
| [`../부하/`](../부하/README.md) | **수동 부하 GUI** (브라우저에서 점수 눈으로) + 노드 강제 스케일용 고부하 | [README](../부하/README.md) |
| `load_user.dump` | DB 시드 덤프 (terraform이 S3 통해 자동 적재) | — |

---

## 🎯 채점 (40점)

| 항목 | 배점 | 무엇 | 어디서 대응 |
|---|---|---|---|
| 비정상 요청 처리 | 4 | 이미지 처리율 + 비정상 요청 403 차단율 | `terraform/` WAF (변수) |
| 고가용성·안정성 | 12 | API별 availability (5초 내 2xx 비율) | 노드/파드 용량 → `tuning/` |
| 성능 효율성 | 12 | API별 응답시간 (user·product ≤0.2s, stress ≤1.0s) | `tuning/` |
| 비용 최적화 | 12 | 인스턴스 비용 ratio (낮을수록↑, 단 성능 30%↑ 조건) | 노드 최소화 → `tuning/` |

> **우선순위: 가용성(게이트) > 성능 > 비용.** avail%를 깨면서 비용 줄이면 무의미.

---

## 🏗️ 아키텍처

```
인터넷 → CloudFront (단일 엔드포인트 + WAFv2) ─┬─ /images/* → S3 (OAC, 캐싱)
                                              └─ 그 외    → ALB → EKS Pod (user/product/stress)
                                                              └ 미정의 경로 → 404
RDS MySQL 8.0 Multi-AZ ← RDS Proxy ← Pod        노드: t3.medium (관리형 NG + Karpenter)
```

- **비정상 요청**: 유효 경로(`/v1/*`)의 공격 = WAF 403 / 없는 경로(`/.env` 등) = ALB 404
- **성능**: product GET CloudFront 캐싱, `/images/*` S3 직캐싱, user.email 인덱스
- **비용**: NAT 제거, t3.medium 최소 대수 + Karpenter consolidation
- 상세·설계 근거: [terraform/README.md](terraform/README.md)

---

## ⏱️ 대회날 워크플로 (시간순)

| 시각 | 할 일 | 명령 / 문서 |
|---|---|---|
| 0:00 | 배포 (2단계) | [terraform/README](terraform/README.md#2-배포-2단계) |
| ~0:20 | 새 앱 바이너리 교체 (제공 시) | [terraform/README](terraform/README.md#3-대회-당일--앱바이너리-교체) |
| ~0:30 | 스모크 테스트 → 엔드포인트 제출 | 200/403/404 확인 후 `terraform output endpoint` |
| ~0:40 | 튜닝 도구 준비 | `tuning/setup.ps1` + `config.ps1`에 `$ENDPOINT`·SLO |
| 1:00~ | **모니터링 + 튜닝 + WAF 반복** | 아래 "목적별" 참고 |
| 종료 | 테스트 부하 중지 / (연습계정) destroy | `terraform destroy -var "k8s_provider_ready=true"` |

### 배포 요약 (상세는 terraform/README)
```powershell
cd terraform
terraform init
terraform apply -auto-approve "-target=aws_eks_node_group.main"      # 1단계: 네트워크+EKS (~15분)
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
terraform apply -auto-approve -var "k8s_provider_ready=true"         # 2단계: 앱·ALB·CF·WAF·DB
terraform output endpoint                                            # 채점 플랫폼에 입력
```

---

## 🧰 목적별 — 언제 뭘 쓰나

트래픽이 도는 동안, 아래 3개를 **동시에 돌리며 반복**한다.

### ① 지금 상태 보기 (모니터링) → [`tools/`](tools/README.md)
```powershell
python tools/dashboard.py --waf-log-group aws-waf-logs-wsi2026    # 웹 대시보드
```
avail%/perf%/pod/node/WAF 한 화면. **여기서 문제를 발견** → ②③으로 대응.
- 「계산」 탭 = 앱별 늘려/줄여/유지 자동 판정 (= `tuning/advise.py`의 웹판)
- 「WAF분석」 탭 = WAF 로그 붙여넣으면 막을 tfvars 값 출력

### ② 느리거나 노드 많음 (성능·비용 튜닝) → [`tuning/`](tuning/README.md)
```powershell
cd tuning
# config.ps1 에 $ENDPOINT 한 번 채우고:
.\loadtest.ps1 180s baseline      # 측정 → 병목 앱 + advise 권장값 자동 출력
.\autotune.ps1 -App stress        # 병목 앱만 자동 스윕 → 최적값
# 나온 값을 terraform/k8s_apps.tf 그 앱에 박고 apply (영구 반영)
```
증상별 처방 (advise.py가 자동 판정):
- **avail% < 99** → cpu↑ / min↑ (**무조건 먼저**)
- **perf 낮고 p95 > SLO** → 그 앱 cpu↑ / util↓
- **노드 과다** → 과투자 앱 cpu↓ / util↑

### ③ 비정상 요청 막기 (WAF) → [`tuning/waf_header_stats.py`](tuning/README.md#waf-차단-분석--waf_header_statspy)
```powershell
python tuning/waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
# 「제안」 섹션의 값을 terraform/terraform.tfvars 에 넣고 apply
```
기본값(스캐너 UA·x-junk·인젝션 등)은 **이미 차단 중** → 로그 보고 **새 공격만** 추가.
전체 운영 절차: [terraform/README "WAF 운영"](terraform/README.md#5-waf-운영--안전-기본값--관찰-추가)

### (보조) 그냥 점수만 눈으로 / 노드 강제 스케일 → [`../부하/`](../부하/README.md)
```powershell
python ../부하/server.py     # 브라우저 GUI: 부하 주고 40점 시뮬레이션
```
- `tuning/`(자동 최적화)과 달리 **수동**. 빠르게 점수 확인용.
- 「🚀 서버 고부하」 = 브라우저 6연결 제한 우회해 **노드를 실제로 스케일**시킬 때.

---

## 🔧 스펙이 바뀌면 (당일 ±변경 대비)

경로·포트·헬스체크는 **terraform 변수 하나**로 전 계층(ALB·WAF·CloudFront·k8s) 반영:

| 바뀐 것 | 변수 (`-var` 또는 `terraform.tfvars`) |
|---|---|
| API prefix (`/v1`→`/v2`) | `api_prefix` (경로가 앱이름과 다르면 `api_paths_override`) |
| 헬스체크 경로 | `healthcheck_path` |
| 컨테이너 포트 | `container_port` |
| 이미지 경로 | `images_prefix` |
| 새 WAF 차단 패턴 | `waf_blocked_user_agents` / `waf_blocked_headers` / `waf_blocked_body_patterns` 등 |

DB 스키마명·테이블·시드 등 변수로 안 되는 것: [terraform/README "스펙 변경 대응"](terraform/README.md#6-스펙-변경-대응--전부-변수-하나로)

---

## ✅ 핵심 직관 3가지
1. **문제 발견은 `tools/` 대시보드**, 대응은 `tuning/`(성능·비용) 또는 WAF(공격).
2. **한 번에 한 앱만** 바꾸고 재측정 (advise가 병목 앱만 짚어줌).
3. **avail% 99%는 절대 사수** — 비용·성능보다 우선.
