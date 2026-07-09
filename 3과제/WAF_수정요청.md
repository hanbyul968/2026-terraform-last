# WAF 규칙 수정 요청 (다른 AI에게 전달용)

## 나의 환경
- OS: Windows, 셸: PowerShell 5.1
- 로컬 작업 경로: `C:\Users\competitor\2026-terraform\3과제\terraform`
- Git 원격: `https://github.com/hnmly/2026-terraform` (이 안의 `3과제/terraform` 폴더)
- Terraform + AWS CLI + kubectl + Docker Desktop 설치돼 있음, 리전 `ap-northeast-2`
- 배포는 2단계로 함:
  ```powershell
  terraform apply -auto-approve "-target=aws_eks_node_group.main"
  aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
  terraform apply -auto-approve -var "k8s_provider_ready=true"
  ```

## 프로젝트 상황 (전국기능경기대회 클라우드컴퓨팅 3과제)
- AWS + EKS 기반으로 user/product/stress 3개 Go 앱을 배포하고, CloudFront → ALB → EKS(Pod) 로 트래픽을 받는 시스템.
- 엔드포인트는 CloudFront 단일화. 앞단에 **WAFv2(CLOUDFRONT scope, us-east-1)** 가 붙어 있음. 파일: `waf.tf`
- 채점 규칙(문제지 원문):
  - 정상 요청 → 200/201
  - **제공하는 엔드포인트로의 "비정상 요청"은 Block, 403 응답**
  - **제공하는 API 외의(존재하지 않는) 경로 요청 → 404**
  - 유효 경로: `/v1/user`, `/v1/product`, `/v1/stress`, `/images/<path>`, `/healthcheck`
- 채점 항목: 비정상요청 처리(4점) / 고가용성=성공률(12점) / 성능=응답시간(12점) / 비용(12점)

## 현재 `waf.tf` 에 들어있는 규칙 (문제가 되는 부분)
커스텀 규칙들:
1. `BadUserAgent` (priority 3): User-Agent 에 sqlmap|nikto|nmap|masscan|acunetix|havij|attack 포함 시 403
2. `SpoofedForwardedFor` (priority 4): X-Forwarded-For 에 127.0.0.1 포함 시 403
3. `OversizedJunkHeader` (priority 5): X-Junk 헤더 존재 시 403
4. `AbnormalBodyPatterns` (priority 6): body 에 `$ne`,`$gt`,`$where`,`sleep(`,`benchmark(` 포함 시 403
5. AWS 관리형 룰 3개 (Common priority 10 / KnownBadInputs 20 / SQLi 30) — 각각 `scope_down_statement` 로 **`/v1/user`, `/v1/product`, `/v1/stress` 경로를 하드코딩(EXACTLY 매칭)** 해서 그 경로에만 적용

## 내 우려 / 요청
대회 당일 새 앱 바이너리가 오면 **요청 스펙(경로/파라미터/필드/Content-Type)이 바뀔 수 있음.**
그런데 위 규칙들 중 일부는 **경로/필드/헤더를 하드코딩**해서:
- 스펙이 바뀌면 → 관리형 룰의 scope_down 경로가 안 맞아 **비정상 요청을 못 막거나**,
- 반대로 구조적 조건(특정 파라미터/Content-Type 요구 같은 규칙을 추가하면) → **바뀐 정상 요청을 403으로 잘못 막아 가용성 점수(12점)가 폭락**할 위험.

### 해줬으면 하는 것
1. **하드코딩·취약한 커스텀 규칙 제거**:
   - `BadUserAgent`, `SpoofedForwardedFor`, `OversizedJunkHeader`, `AbnormalBodyPatterns` 처럼 임의로 넣은 커스텀 차단 규칙은 **제거**. (정상 트래픽 오탐 위험 + 스펙 변경에 취약)
2. **스펙 변경에 안전한 것만 유지**:
   - AWS 관리형 룰(Common / KnownBadInputs / SQLi)은 유지하되, **경로 하드코딩(scope_down)을 어떻게 할지** 검토.
     - 관리형 룰을 유효 API 경로 전체(`/v1/*` 등)에 적용하되, 경로 하나만 바꾸면 되도록 **변수(variable)로 빼서** 대회날 쉽게 수정 가능하게.
   - SQLi/XSS 같은 공격 시그니처 차단은 정상 요청에 절대 안 나오므로 스펙 변경과 무관하게 안전 → 유지.
3. **대회날 손쉽게 규칙 추가/수정 가능한 구조로**:
   - 차단할 경로/파라미터/조건을 **`variables.tf` 의 변수나 `locals.tf` 로 분리**해서, 대회날 실제 요청 형태(정상/비정상)를 확인한 뒤 값만 바꿔 `apply` 하면 되도록.
   - 예: `var.api_paths = ["/v1/user","/v1/product","/v1/stress"]` 처럼 리스트로 관리 → 경로 바뀌면 이 변수만 수정.
   - "필드 누락/Content-Type 오류 등 malformed 요청을 403으로 막고 싶을 때, 정상 요청을 안 막으면서 추가하는 방법"을 **주석이나 예시로 `waf.tf` 에 남겨서** 대회날 바로 활성화할 수 있게.
4. 수정 후 `terraform validate` 통과 확인하고, 무엇을 지웠고 무엇을 남겼는지 요약해줘.

### 주의
- kubernetes/helm/kubectl provider 는 `var.k8s_provider_ready=true` 일 때만 실제 클러스터에 붙음. WAF만 건드릴 거면 provider 관련은 신경 안 써도 됨.
- WAF 는 CloudFront scope 라서 `provider = aws.us_east_1` (us-east-1) 로 생성됨.
- 절대 정상 요청(200/201 나와야 하는 것)을 막는 규칙을 기본값으로 넣지 말 것. 가용성 점수가 최우선.
