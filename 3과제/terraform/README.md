# 2026 전국기능경기대회 클라우드컴퓨팅 3과제 — Terraform 인프라

System Operation 과제(3시간, 트래픽은 시작 1시간 뒤 주입) 전체 인프라를 `terraform apply` 로 구축한다.
**실행 환경: Windows PowerShell + Docker Desktop, 리전 `ap-northeast-2`.**

---

## 0. 대회날 타임라인 (이 순서대로만 하면 됨)

| 시각 | 할 일 | 명령 |
|---|---|---|
| 0:00 | 자격증명 + 배포 시작 | `aws configure` → 아래 [2. 배포](#2-배포-2단계) |
| ~0:20 | 새 앱 바이너리 반영 | [3. 바이너리 교체](#3-대회-당일--앱바이너리-교체) |
| ~0:30 | 스모크 테스트 + 엔드포인트 제출 | [4. 검증](#4-스모크-테스트) → `terraform output endpoint` |
| ~0:40 | 부하도구 준비 | `..\tuning\setup.ps1` → `loadtest.ps1` baseline |
| 1:00~ | 트래픽 시작 — 모니터링 | 대시보드 + `waf_header_stats.py` 로 관찰 |
| 수시 | 새 공격 패턴 차단 / 성능 튜닝 | [5. WAF 운영](#5-waf-운영--안전-기본값--관찰-추가) / `..\tuning\autotune.ps1 -App <앱>` |
| 종료 | 테스트 부하 중지 확인 | (연습 계정이면 `terraform destroy`) |

---

## 1. 아키텍처

```
인터넷 → CloudFront(단일 엔드포인트, WAFv2) ─┬─ /images/* → S3 (OAC, 캐싱)
                                             └─ 기타      → ALB → EKS Pod (user/product/stress)
                                                             └ 미정의 경로 → 404 fixed-response
RDS MySQL 8.0 Multi-AZ (db.t3.micro) ← RDS Proxy ← Pod
```

| 계층 | 리소스 | 비고 |
|------|--------|------|
| 네트워크 | VPC + 2-AZ public subnet | NAT 없음(비용), IGW만 |
| 컨테이너 | EKS 1.35 + t3.medium 노드그룹 | Fargate/Lambda 금지 준수 |
| 오토스케일 | Karpenter(노드) + HPA(파드) | 부하 시만 확장, idle 시 통합 |
| 레지스트리 | ECR ×3 | apply 안에서 docker build+push 자동 |
| DB | RDS MySQL 8.0 Multi-AZ gp3 | identifier `apdev-rds-instance` |
| 엔드포인트 | CloudFront → ALB + S3 | 단일화, product GET 캐싱 |
| 보안 | WAFv2 (관리형 3종 + 변수 기반 커스텀 룰) | 비정상 403 / 미정의 404 |

### 채점 대응 요약 (40점)

* **가용성 12점**: 2-AZ 노드 + RDS Multi-AZ + pod topology spread + HPA. **최우선 — 어떤 튜닝도 avail% 를 깨면 안 됨.**
* **성능 12점 (≤0.2s)**: product GET CloudFront 캐싱(id 쿼리 기준 10s) + 앱 내 캐시, user.email 인덱스(db-init 자동), `/images/*` S3 직캐싱.
* **비용 12점**: NAT 제거, t3.medium 최소 대수 + Karpenter consolidation.
* **비정상 4점**: WAF가 유효 경로의 비정상 요청 403, ALB default 가 미정의 경로 404. → [5. WAF 운영](#5-waf-운영--안전-기본값--관찰-추가)

---

## 2. 배포

kubernetes/helm/kubectl provider 는 EKS 클러스터 엔드포인트에 의존한다. 클러스터가 **없을 때**
provider 가 `https://localhost` 로 붙어 아래 에러가 난다:

```
Error: ... dial tcp [::1]:443: ... the target machine actively refused it.
Error: Kubernetes cluster unreachable ...
```

이를 피하려고 `var.k8s_provider_ready` 로 제어한다 (기본값 `true` = 평상시).

### 평상시 (클러스터가 이미 있음) — 한 방

```powershell
cd C:\Users\competitor\2026-terraform\3과제\terraform
terraform init
terraform apply -auto-approve      # -target 안 써서 PowerShell 인자 쪼개짐 문제도 없음
terraform output endpoint          # http://dXXXX.cloudfront.net ← 채점 플랫폼에 프로토콜+주소만 (경로 X)
```

### 최초 구축 / 클러스터를 새로 만들 때만 — 2단계

클러스터가 없으면 provider 엔드포인트가 unknown 이라 위 localhost 에러가 난다. **먼저 클러스터만**
만든 뒤(그때는 provider 를 더미로 두게 `k8s_provider_ready=false`), 클러스터가 생긴 다음 전체를 apply 한다.

```powershell
cd C:\Users\competitor\2026-terraform\3과제\terraform
terraform init

# 1단계: 클러스터+노드그룹+애드온+OIDC 만 (~15분). PowerShell 이 -target 의 점(.)을
#        쪼개지 않도록 반드시 --% (stop-parsing) 를 붙인다.
terraform apply --% -var k8s_provider_ready=false -target=aws_eks_cluster.this -target=aws_eks_node_group.main -target=aws_iam_openid_connect_provider.eks -target=aws_eks_addon.coredns -target=aws_eks_addon.kube_proxy -target=aws_eks_addon.vpc_cni -target=aws_eks_addon.metrics_server

# 2단계: kubeconfig + 나머지 전체 (앱 빌드·push, ALB, CloudFront, WAF, DB 시드까지 자동)
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
terraform apply -auto-approve
```

> **PowerShell 주의**: `terraform apply -target=aws_eks_cluster.this ...` 를 그냥 치면
> `Error: Too many command line arguments` / `Invalid target "aws_eks_cluster"` 가 난다 (PowerShell 이 값을 쪼갬).
> → `terraform apply --% -target=...` 처럼 **`--%` 를 apply 뒤에** 붙이면 이후 인자를 그대로 넘긴다.

* `null_resource.build_push` 가 apply 안에서 ECR 로그인 + docker build + push 를 수행 (Docker Desktop 필수).
* db-init Job 이 테이블 생성 + `load_user.dump` 적재 (user 테이블이 비어있을 때만 → 재실행 안전).
  덤프 안의 잘못된 `USE <db>;` 줄은 적재 시 자동 제거된다.
* 명명 프로파일 사용 시 매 apply 에 `-var aws_profile=<이름>` 추가.
* **WAF 룰만 빠르게 바꿀 때**: `terraform apply --% -target=aws_wafv2_web_acl.cloudfront -auto-approve`

---

## 3. 대회 당일 — 앱(바이너리) 교체

배포에 쓰이는 것은 소스가 아니라 **`application/binary/{user,product,stress}`** (파일명 고정).

```powershell
# 1) 받은 바이너리 덮어쓰기 (chmod 불필요 — Dockerfile 이 COPY --chmod=0755)
Copy-Item C:\받은경로\user    ..\application\binary\user    -Force
Copy-Item C:\받은경로\product ..\application\binary\product -Force
Copy-Item C:\받은경로\stress  ..\application\binary\stress  -Force

# 2) 반드시 "새 태그"로 apply → 빌드+push+롤링 재배포가 한 번에
terraform apply -auto-approve -var "k8s_provider_ready=true" -var app_image_tag="v$([int](Get-Date -UFormat %s))"

# 3) 롤아웃 확인
kubectl -n app rollout status deploy/user
kubectl -n app rollout status deploy/product
kubectl -n app rollout status deploy/stress
```

> 같은 태그로 다시 빌드만 하면 롤아웃이 안 일어남 → `kubectl -n app rollout restart deploy/user deploy/product deploy/stress`

---

## 4. 스모크 테스트

```powershell
$EP = (terraform output -raw endpoint)
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/healthcheck"                                              # 200
curl.exe -s -o NUL -w "%{http_code}`n" -X POST -H "Content-Type: application/json" `
  -d '{"requestid":"1","uuid":"u1","username":"smoke1","email":"smoke1@example.org"}' "$EP/v1/user"    # 201
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v1/user?email=smoke1@example.org&requestid=1&uuid=u1"      # 200
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v1/none"                                                   # 404
curl.exe -s -o NUL -w "%{http_code}`n" -A "sqlmap/1.7" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"  # 403 (WAF)
curl.exe -s -o NUL -w "%{http_code}`n" -H "X-Junk: 1" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"   # 403 (WAF)
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/.env"                                                      # 404 (403 아님!)
```

정상요청 200/201 · 비정상 403 · 미정의 404 — 셋 다 맞아야 정상.

---

## 5. WAF 운영 — 안전 기본값 + 관찰 추가

> **원칙**: 오탐 0이 검증된 패턴은 **처음부터 차단**(처리율은 전 기간 누적 % → 늦게 켜면 영구 감점),
> **새 패턴만** 로그 관찰로 추가한다. 차단 룰은 전부 변수라 `waf.tf` 는 손댈 필요 없다.

### 기본으로 켜져 있는 것 (variables.tf 기본값)

| 변수 | 기본값 | 막는 것 |
|---|---|---|
| `waf_blocked_user_agents` | sqlmap, nikto, nmap, masscan, acunetix, havij, nuclei, wpscan, dirbuster, gobuster, attack | 스캐너/공격도구 UA |
| `waf_blocked_headers` | `["x-junk"]` | 쓰레기 헤더가 존재하는 요청 |
| `waf_blocked_header_values` | `[]` | 특정 헤더 값에 문자열 포함 시 (예: `content-type`=`multipart/form-data`) |
| `waf_blocked_body_patterns` | `$ne` `$gt` `$where` `sleep(` `benchmark(` | 인젝션 body 토큰 |
| `waf_blocked_query_patterns` | `[]` | 쿼리스트링(URL 디코딩+소문자 후) 포함 시 (예: `/etc/passwd`, `{{`) — 명령주입·SSTI·경로탐색 |
| `waf_block_private_xff` | `true` | XFF 에 루프백/사설/169.254 IP (위조) |
| AWS 관리형 룰 3종 | 항상 ON | SQLi/XSS/KnownBadInputs (유효 경로만 scope) |

* 전부 정상 트래픽(hey/Go/curl/브라우저 UA, 표준 헤더, 평범한 JSON)에 **절대 안 나오는 것만** 골라놨다.
* 커스텀 룰은 **유효 엔드포인트에서만** 동작 → `/.env` 같은 미정의 경로는 여전히 404 (스펙 준수).
* **오탐 의심 시**(avail% 하락): 해당 변수만 `[]` / `false` 로 바꿔 apply → 즉시 해제.

### 대회날 루프: 관찰 → 추가 → 확인

```powershell
# 1) 관찰 — "아직 안 막힌 비정상/의심" + tfvars 제안까지 자동 출력
cd ..\tuning
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

```hcl
# 2) terraform/terraform.tfvars 에 제안 복붙 (⚠ 리스트는 기본값을 덮어쓰므로 기본값+새것 전부 나열)
waf_blocked_user_agents   = ["sqlmap", "nikto", "nmap", "masscan", "acunetix", "havij",
                             "nuclei", "wpscan", "dirbuster", "gobuster", "attack", "<새 스캐너>"]
waf_blocked_headers       = ["x-junk", "<새 쓰레기 헤더>"]                # 소문자
waf_blocked_header_values = [{ header = "referer", value = "evil.com" }] # 헤더 값 매칭
waf_blocked_body_patterns = ["$ne", "$gt", "$where", "sleep(", "benchmark(", "<새 토큰>"]
```

```powershell
# 3) 적용 + 확인 (403 나와야 함, /.env 는 여전히 404, loadtest avail% 유지)
cd ..\terraform ; terraform apply -auto-approve -var "k8s_provider_ready=true"
curl.exe -s -o NUL -w "%{http_code}`n" -H "X-새헤더: 1" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"
```

* 판단 기준: **경로가 유효한가**부터 본다. 미정의 경로(/.env, /admin, /v1/users)는 막는 게 아니라 404 가 정답.
* 확신 없는 패턴은 `waf_custom_rule_action = "count"` 로 넣고 로그 확인 후 `"block"` 복귀.
  (count 는 **기본 패턴까지 전부** 관찰 모드가 되므로 확인 즉시 되돌릴 것)

---

## 6. 스펙 변경 대응 — 전부 변수 하나로

경로·포트·헬스체크가 변수로 통합돼 있어 **연쇄 수정이 없다**. `-var` 또는 `terraform.tfvars` 로:

| 스펙 변경 | 변수 | 자동 반영되는 곳 |
|---|---|---|
| API prefix (`/v1`→`/v2`) | `api_prefix` | ALB 리스너·deny_direct, WAF scope, CloudFront product 캐시 |
| 경로가 앱 이름과 불일치 | `api_paths_override = ["/v2/member", ...]` | 위와 동일 (403/404 판정 기준 포함) |
| 헬스체크 경로 | `healthcheck_path` | ALB TG·리스너 + k8s probe 6곳 |
| 컨테이너 포트 (8080 고정이지만 만약) | `container_port` | Deployment·probe·Service·TG·SG |
| 이미지 경로 (`/images`) | `images_prefix` | CloudFront 캐시 + URI rewrite 함수 |
| 리전/노드타입/EKS버전/노드수 | `region`+`azs` / `node_instance_type` / `eks_version` / `node_*_size` | |
| 이름 충돌 시 새 배포 | `project` | 모든 리소스 이름 |

변수로 안 되는 것 (직접 수정):

| 변경 | 고칠 곳 |
|---|---|
| RDS identifier | `rds.tf` `identifier` |
| 스키마명 (`dev`) | `variables.tf` `db_name` **+ `load_user.dump` 첫 줄 `USE`** (둘 다!) |
| DB 유저 | `variables.tf` `db_username` |
| 테이블 스키마 | `k8s_base.tf` db-init Job 의 `CREATE TABLE` |
| 새 환경변수 요구 | `k8s_base.tf` ConfigMap/Secret (env_from 으로 자동 주입됨) |
| S3 버킷명 지정 | `s3.tf` |

> ⚠ terraform 변수를 바꿔도 **부하 도구(`tuning/config.ps1`, `부하/app.js`)의 URL·body 는 별도로** 새 스펙에 맞춰야 한다.

---

## 7. 성능/비용 튜닝

측정·자동 튜닝은 [`../tuning/README.md`](../tuning/README.md) 참고. 요약:

```powershell
cd ..\tuning
.\loadtest.ps1 $EP 180s baseline      # 병목 앱 찾기 (perf% 낮은 앱)
.\autotune.ps1 $EP -App stress        # 그 앱만 정밀 스윕 → 우승값 그대로 반영 가능
```

우승값은 `k8s_apps.tf` 의 해당 앱 `requests.cpu` / HPA `average_utilization`·`min_replicas` 에 박고 apply (kubectl patch 는 재배포 시 사라짐). **avail% < 99 면 비용보다 무조건 용량부터.**

---

## 8. 트러블슈팅

| 증상 | 처방 |
|---|---|
| `AlreadyExists` 409 | 옛 리소스 잔재. state 있는 쪽에서 destroy, 안 되면 `project` 변경 + state 삭제 후 재apply |
| `NodeCreationFailure` | state 오염으로 라우트 association 이 옛 서브넷을 가리킴. `terraform state rm 'aws_route_table_association.public[0]' ...` → 재apply → 노드그룹 삭제 후 재생성. 깨끗한 state(새 계정)에선 발생 안 함 |
| Service 생성 전부 거부 (`mservice.elbv2.k8s.aws` webhook) | `kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook` (validating 도) → 재apply |
| 애드온/helm 이 FAILED 로 낌 | `aws eks delete-addon --addon-name metrics-server ...` / `helm uninstall karpenter -n kube-system` → 재apply |
| `Unauthorized` 일시 오류 | 액세스 전파 타이밍 → 재apply 로 해소 |
| `error during connect ... docker daemon` | Docker Desktop 미실행 |
| destroy 가 `connectex: No connection` | `-var "k8s_provider_ready=true"` 누락. 클러스터가 이미 없으면: `terraform state list | Select-String "kubernetes_|helm_|kubectl_" | ForEach-Object { terraform state rm $_.ToString().Trim() }` 후 destroy |
| 파드가 ALB 타겟에 안 붙음 | `kubectl -n kube-system get deploy aws-load-balancer-controller` Ready 확인 (TargetGroupBinding 이 pod IP 등록) |

### 정리 (연습 계정 필수)

```powershell
terraform destroy -auto-approve -var "k8s_provider_ready=true"
```

---

## 9. 파일 구조

```
terraform/
├── versions.tf / providers.tf / variables.tf / locals.tf / outputs.tf
│                                # variables: 경로·포트·WAF 차단 패턴 전부 여기서 제어
├── vpc.tf                       # VPC + 2-AZ public subnet + IGW + S3 VPCe
├── ecr.tf / build.tf            # ECR 3개 + apply 내 docker build/push (PowerShell)
├── rds.tf / rds_proxy.tf        # MySQL 8.0 Multi-AZ + 커넥션 풀링
├── s3.tf / seed.tf              # 이미지 버킷(OAC) + 시드 덤프 업로드
├── eks.tf / karpenter.tf        # 클러스터 1.35 + 노드그룹 + Karpenter 1.13
├── iam.tf + policies/           # IRSA + ALB controller 정책
├── lb_controller.tf             # AWS LB Controller (TargetGroupBinding 용)
├── alb.tf                       # ALB + TG + 리스너 (유효경로 forward / 미정의 404 / 직접접근 403)
├── k8s_base.tf                  # namespace + secret + db-init Job
├── k8s_apps.tf                  # user/product/stress Deploy+Svc+HPA  ← 튜닝값 반영처
├── waf.tf                       # WAFv2 (관리형 + 변수 기반 커스텀 룰)  ← 수정할 일 없음
└── cloudfront.tf                # 단일 엔드포인트 + 캐싱 + /images rewrite
```
