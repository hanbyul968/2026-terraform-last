# 3과제 System Operation — Terraform 인프라

트래픽은 경기 시작 **1시간 뒤** 주입된다. 그 전에 배포·검증을 끝내는 것이 목표.

- 실행 환경: **Windows PowerShell + Docker Desktop**, 리전 `ap-northeast-2`
- 배점 40점은 **전부 부하 테스트 결과**로 매겨진다 (구성 점수 없음)

> 새 PC라 terraform/aws/kubectl/docker가 아직 없거나, **새 AWS 계정**에 처음 배포한다면
> 먼저 [../README "새 PC · 새 계정에서 처음 시작하기"](../README.md#새-pc--새-계정에서-처음-시작하기)를 본다.
> 패키지 설치, 자격증명, 버킷 이름 전역 고유 설정이 거기에 있다.

---

## 0. 대회날 순서

| 시각  | 할 일                            | 바로가기                                     |
| ----- | -------------------------------- | -------------------------------------------- |
| 0:00  | 자격증명 → 배포 시작            | [2. 배포](#2-배포)                            |
| ~0:20 | 받은 바이너리 반영               | [3. 바이너리 교체](#3-바이너리-교체)          |
| ~0:25 | **스펙이 바뀌었으면 대응** | [4. API/스펙 변경 대응](#4-apispec-변경-대응) |
| ~0:35 | 스모크 테스트 → 엔드포인트 제출 | [5. 스모크 테스트](#5-스모크-테스트)          |
| ~0:45 | 부하도구 준비                    | `..\tuning\setup.ps1` → `loadtest.ps1`  |
| 1:00~ | 트래픽 시작. 모니터링 + 튜닝     | [7. 튜닝](#7-성능비용-튜닝)                   |
| 종료  | 부하 중지 확인                   |                                              |

---

## 1. 아키텍처

```
인터넷 → CloudFront (단일 엔드포인트, WAFv2)
           ├─ /images/*   → S3 (OAC, 1일 캐싱)
           ├─ /v1/product → ALB (id 쿼리 기준 10s 캐싱)
           └─ 그 외       → ALB ─→ EKS Pod (user / product / stress)
                                └ 미정의 경로 → 404 fixed-response
                                └ CloudFront 우회 직접호출 → 403

Pod → RDS Proxy (커넥션 풀러) → RDS MySQL 8.0 Multi-AZ (db.t3.micro)
```

| 계층       | 구성                                | 비고                                |
| ---------- | ----------------------------------- | ----------------------------------- |
| 네트워크   | VPC + 2-AZ public subnet + IGW      | NAT 없음 (비용)                     |
| 컨테이너   | EKS 1.35 + t3.medium                | Fargate/Lambda 미사용 (문제지 §15) |
| 오토스케일 | Karpenter(노드) + HPA(파드)         | idle 시 노드 통합                   |
| DB         | RDS MySQL 8.0 Multi-AZ gp3          | `apdev-rds-instance`, db.t3.micro |
| DB 커넥션  | RDS Proxy                           | 파드 풀러 없음 — 아래 참고          |
| 엔드포인트 | CloudFront → ALB + S3              | 단일화                              |
| 보안       | WAFv2 관리형 3종 + 변수 기반 커스텀 | 비정상 403 / 미정의 404             |

**RDS Proxy 를 쓰는 이유**: HPA 로 user/product 파드가 늘어나면 (파드 × MaxOpenConns) 가
db.t3.micro 의 `max_connections` 를 넘겨 커넥션 폭주로 죽는다. Proxy 가 다수 클라이언트를 소수
백엔드 커넥션으로 멀티플렉싱해 이를 막는다. 파드형 풀러(ProxySQL)를 쓰지 않으므로 노드 CPU/메모리를
앱에 전부 쓸 수 있다.

⚠ **인증 전제 (가장 중요)**: `rds_proxy.tf` 의 `client_password_auth_type = "MYSQL_NATIVE_PASSWORD"` 가
반드시 적용돼야 한다. 기본값인 `MYSQL_CACHING_SHA2_PASSWORD` 로 남으면 제공된 Go 바이너리
(go-sql-driver)가 비-TLS 에서 그 방식을 처리하지 못해 **모든 앱이 `Error 1045 Access denied` 로
CrashLoopBackOff** 된다. db-init 의 `mysql_native_password` ALTER 는 프록시→DB 구간용이고,
클라이언트→프록시 구간은 이 설정이 담당한다.

**함정**: `mysql` CLI 는 caching_sha2 여도 프록시 접속이 **성공**한다. CLI 로 검증하면 문제를 놓친다.
반드시 앱 로그로 확인한다.

```powershell
aws rds describe-db-proxies --db-proxy-name wsi2026-proxy --region ap-northeast-2 `
  --query "DBProxies[0].Auth[0].ClientPasswordAuthType" --output text     # MYSQL_NATIVE_PASSWORD 여야 함
kubectl -n app get pods                                                   # CrashLoopBackOff 없어야 함
kubectl -n app logs deploy/user --tail=20 | Select-String 1045             # 아무것도 안 나와야 함
```

**terraform 이 이 값을 수정하지 못하는 경우가 있다.** 기존 프록시에 대해 apply 는 성공하는데 AWS 는
옛 값을 유지한 사례가 있어, `aws_db_proxy` 에 `postcondition` 을 걸어 apply 가 실패하게 해뒀다.
그래도 걸리면 CLI 로 직접 바꾸고 앱을 재시작한다.

```powershell
$sec = (aws rds describe-db-proxies --db-proxy-name wsi2026-proxy --region ap-northeast-2 --query "DBProxies[0].Auth[0].SecretArn" --output text)
aws rds modify-db-proxy --db-proxy-name wsi2026-proxy --region ap-northeast-2 `
  --auth "AuthScheme=SECRETS,SecretArn=$sec,IAMAuth=DISABLED,ClientPasswordAuthType=MYSQL_NATIVE_PASSWORD"
# Status 가 available 로 돌아온 뒤
kubectl -n app rollout restart deploy/user deploy/product
```

⚠ **비용**: RDS Proxy 는 DB 인스턴스 vCPU 시간당 과금(db.t3.micro = 2 vCPU → 약 $0.03/h).
채점의 "인스턴스 비용 ratio" 에 EC2·RDS 인스턴스만 잡히면 불리하지 않지만, 확실하지 않으므로
노드를 아끼는 이득과 비교해 판단한다.

### 배점 대응 (40점)

| 항목                                      | 배점 | 대응                                                                                                        |
| ----------------------------------------- | ---- | ----------------------------------------------------------------------------------------------------------- |
| 가용성                                    | 12   | 2-AZ 노드 + RDS Multi-AZ + topology spread + HPA.**최우선 — 어떤 튜닝도 avail%를 깨면 안 됨**        |
| 성능 (user/product ≤0.2s, stress ≤1.0s) | 12   | product GET CloudFront 캐싱,`user.email` 인덱스, `/images/*` S3 캐싱, CPU limit 미설정(CFS 스로틀 회피) |
| 비용 (ratio 0.5~)                         | 12   | NAT 제거, t3.medium 최소 대수, Karpenter consolidation 30s, RDS Proxy 제거                                  |
| 비정상 요청                               | 4    | 유효 경로의 비정상 → WAF 403 / 미정의 경로 → ALB 404                                                      |

---

## 2. 배포

`kubernetes`/`helm`/`kubectl` provider가 EKS 엔드포인트에 의존한다. 클러스터가 **없는 상태**에서
전체 apply를 하면 provider가 `https://localhost`로 붙어 실패한다.

### 최초 구축 (state가 비어 있을 때) — 2단계

```powershell
cd C:\Users\competitor\2026-terraform\3과제\terraform
terraform init

# 1단계: 클러스터만 (~15분). PowerShell이 -target의 점을 쪼개지 않게 --% 필수
terraform apply --% -var k8s_provider_ready=false -target=aws_eks_cluster.this -target=aws_eks_node_group.main -target=aws_iam_openid_connect_provider.eks -target=aws_eks_addon.coredns -target=aws_eks_addon.kube_proxy -target=aws_eks_addon.vpc_cni -target=aws_eks_addon.metrics_server

# 2단계: 나머지 전체 (이미지 빌드/push, ALB, CloudFront, WAF, DB 시드까지 자동)
#   클러스터 이름을 외우지 않는다 — output 이 정확한 명령을 그대로 준다
#   (project 변수를 바꿨어도 항상 맞는 이름이 나온다)
Invoke-Expression (terraform output -raw kubeconfig_cmd)
terraform apply -auto-approve

terraform output endpoint     # ← 채점 플랫폼에 제출 (프로토콜+주소만, 경로 X)
```

### 클러스터가 이미 있을 때

```powershell
terraform apply -auto-approve
```

- `null_resource.build_push`가 apply 안에서 ECR 로그인 + docker build + push (Docker Desktop 필수)
- db-init Job이 테이블 생성 + `load_user.dump` 적재 (user 테이블이 빈 경우만 → 재실행 안전)
- 명명 프로파일 사용 시 매 apply에 `-var aws_profile=<이름>`
- S3 버킷명 충돌(`BucketAlreadyExists`) 시 `-var bucket_prefix=<고유값>`

> **`--%` 규칙**: `-target`을 쓸 때만 필요하다. `terraform apply --% -target=...` 처럼 apply 바로 뒤에
> 붙인다. 없으면 `Invalid target` / `Too many command line arguments`가 난다.

---

## 3. 바이너리 교체

배포되는 것은 소스가 아니라 **`../application/binary/{user,product,stress}`** (파일명 고정).

```powershell
Copy-Item C:\받은경로\user    ..\application\binary\user    -Force
Copy-Item C:\받은경로\product ..\application\binary\product -Force
Copy-Item C:\받은경로\stress  ..\application\binary\stress  -Force

terraform apply -auto-approve
```

이미지 태그가 **바이너리 해시**에서 자동 파생되므로(`build.tf`), 바이너리가 바뀌면 태그가 바뀌어
롤링 재배포까지 자동으로 일어난다. `-var app_image_tag=...`는 강제 지정할 때만 쓴다.

```powershell
kubectl -n app rollout status deploy/user
kubectl -n app rollout status deploy/product
kubectl -n app rollout status deploy/stress
```

---

## 4. API/스펙 변경 대응

대회날 API가 바뀌는 시나리오별 대응. **대부분 변수만 바꾸면 되고**, 연쇄 수정이 필요한 것은
아래 표에 파일까지 적어뒀다.

### 4-1. 변수만 바꾸면 되는 것

`variables.tf`를 수정하고 `terraform apply -auto-approve`.

| 바뀐 것                                     | 변수                                                               | 자동 반영되는 곳                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| API prefix`/v1` → `/v2`                | `api_prefix = "/v2"`                                             | ALB 리스너 규칙, 403 판정(deny_direct), WAF scope-down, CloudFront product 캐시 동작 |
| 경로가 앱 이름과 불일치(예: `/v2/member`) | `api_paths_override = ["/v2/member","/v1/product","/v1/stress"]` | 위와 동일 (403/404 판정 기준 포함)                                                   |
| 헬스체크 경로                               | `healthcheck_path = "/healthz"`                                  | ALB TG 헬스체크 + 리스너 규칙 + k8s probe 6곳                                        |
| 컨테이너 포트                               | `container_port = 9090`                                          | Deployment/probe/Service/ALB TG/SG                                                   |
| 이미지 경로`/images`                      | `images_prefix = "/static"`                                      | CloudFront 캐시 동작 + URI rewrite 함수                                              |
| 노드 타입/수, EKS 버전                      | `node_instance_type`, `node_*_size`, `eks_version`           |                                                                                      |
| 리전                                        | `region` + `azs`                                               |                                                                                      |

```powershell
# 예) prefix가 /v2로 바뀐 경우
terraform apply -auto-approve -var api_prefix=/v2
$EP = (terraform output -raw endpoint)
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v2/user?email=x@x.org&requestid=1&uuid=1"   # 200
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"   # 404 (옛 경로)
```

### 4-2. 앱이 추가/이름 변경된 경우

앱 목록이 4곳에 있다. **전부 같이** 고쳐야 한다.

| 파일            | 고칠 곳                                                                                 |
| --------------- | --------------------------------------------------------------------------------------- |
| `ecr.tf`      | `for_each = toset(["user","product","stress"])` 2곳 (repository + lifecycle)          |
| `build.tf`    | `local.app_bins` 맵, `local.build_lines`의 `for app in [...]`                     |
| `alb.tf`      | `local.tg_prefix`(TG 이름 접두어, 2자 이내) + `local.node_ports`(NodePort 30083...) |
| `k8s_apps.tf` | Deployment + Service + HPA 블록 복사 (기존 앱 블록을 그대로 복제 후 이름만 변경)        |

`local.api_paths`는 `local.node_ports`의 키에서 자동 계산되므로, `alb.tf`만 고치면 ALB 규칙·WAF
scope·403/404 판정이 따라온다. 경로가 앱 이름과 다르면 `api_paths_override`로 통째 지정.

### 4-3. 새 환경변수를 요구하는 경우

앱 컨테이너는 값을 직접 박지 않고 **Secret/ConfigMap을 `env_from`으로 통째 주입**받는다.
키만 추가하면 env로 노출된다. 파일은 `k8s_base.tf`.

| 종류                              | 넣는 곳                                  |
| --------------------------------- | ---------------------------------------- |
| 비밀값 (비번·토큰)               | `kubernetes_secret.db` 의 `data`     |
| 일반값 (엔드포인트·플래그·버킷) | `kubernetes_config_map.s3` 의 `data` |

```hcl
resource "kubernetes_config_map" "s3" {
  data = {
    S3_BUCKET  = aws_s3_bucket.images.bucket
    AWS_REGION = var.region
    FOO        = "bar"      # ← 추가
  }
}
```

`user`/`product`는 이미 두 `env_from`이 걸려 있어 자동 반영된다. **`stress`는 `env_from`이 없으므로**
필요하면 `k8s_apps.tf`의 stress 컨테이너에 추가한다.

```powershell
terraform apply -auto-approve
kubectl -n app rollout restart deploy/user deploy/product   # env_from은 재시작해야 반영
kubectl -n app exec deploy/user -- printenv | Select-String FOO
```

### 4-4. DB 스키마/테이블이 바뀐 경우

| 바뀐 것            | 고칠 곳                                                                          |
| ------------------ | -------------------------------------------------------------------------------- |
| 테이블 스키마      | `k8s_base.tf` db-init Job의 `CREATE TABLE`                                   |
| 스키마명 (`dev`) | `variables.tf` `db_name` **+ `load_user.dump`의 `USE` 줄** (둘 다) |
| DB 유저            | `variables.tf` `db_username`                                                 |
| RDS identifier     | `rds.tf` `identifier`                                                        |

db-init Job은 `wait_for_completion = true`라 apply가 완료를 기다린다. 스키마를 바꿨으면 Job을
다시 돌려야 한다:

```powershell
kubectl -n app delete job db-init
terraform apply -auto-approve
kubectl -n app logs job/db-init
```

> 조회 패턴이 바뀌면 **인덱스도 같이** 손대야 성능 점수가 나온다. 현재는 `user.email` 조회를
> 위해 `idx_email`을 db-init에서 만든다. 새 조회 조건이 생기면 같은 자리에 인덱스를 추가한다.

### 4-5. 응답 코드/캐싱 관련이 바뀐 경우

| 바뀐 것                    | 고칠 곳                                                                          |
| -------------------------- | -------------------------------------------------------------------------------- |
| 미정의 경로 응답 (404)     | `alb.tf` `aws_lb_listener.http` 의 `default_action`                        |
| 비정상 요청 응답 (403)     | `alb.tf` `aws_lb_listener_rule.deny_direct`                                  |
| product 캐시 TTL           | `cloudfront.tf` `aws_cloudfront_cache_policy.product_get` 의 `default_ttl` |
| 캐시 키에 쓸 쿼리 파라미터 | 같은 리소스의`query_strings { items = ["id"] }`                                |
| 이미지 캐시 TTL            | `aws_cloudfront_cache_policy.images`                                           |

⚠ **캐시 키 주의**: 모든 요청에 `requestid`·`uuid`가 붙는다(매번 다른 값). 캐시 키에 이 두 개가
들어가면 히트율이 0이 된다. `product_get` 정책이 `whitelist`로 `id`만 쓰는 이유다. 새로 캐싱할
경로를 추가할 때도 **반드시 whitelist**로 필요한 파라미터만 지정할 것.

> terraform 변수를 바꿨으면 **부하 도구(`tuning/config.ps1`, `부하/app.js`)의 URL·body도** 새 스펙에
> 맞춰야 한다. 자동 반영되지 않는다.

---

## 5. 스모크 테스트

```powershell
$EP = (terraform output -raw endpoint)
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/healthcheck"                                              # 200
curl.exe -s -o NUL -w "%{http_code}`n" -X POST -H "Content-Type: application/json" `
  -d '{"requestid":"1","uuid":"u1","username":"smoke1","email":"smoke1@example.org"}' "$EP/v1/user"    # 201
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v1/user?email=smoke1@example.org&requestid=1&uuid=u1"      # 200
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/v1/none"                                                   # 404
curl.exe -s -o NUL -w "%{http_code}`n" -A "sqlmap/1.7" "$EP/v1/user?email=x@x.org&requestid=1&uuid=1"  # 403
curl.exe -s -o NUL -w "%{http_code}`n" "$EP/.env"                                                      # 404 (403 아님)
```

정상 200/201 · 비정상 403 · 미정의 404 — 셋 다 맞아야 한다.

---

## 6. WAF 운영

**원칙**: 오탐 0이 검증된 패턴은 처음부터 차단(처리율은 전 기간 누적 %라 늦게 켜면 영구 감점).
새 패턴만 로그 관찰로 추가한다. 차단 룰은 전부 변수라 `waf.tf`는 손대지 않는다.

기본 ON: `waf_blocked_user_agents`(스캐너 UA), `waf_blocked_headers`(쓰레기 헤더),
`waf_blocked_body_patterns`(인젝션 토큰), `waf_blocked_query_patterns`,
`waf_block_private_xff`, AWS 관리형 3종(SQLi/XSS/KnownBadInputs).
커스텀 룰은 **유효 엔드포인트에서만** 동작하므로 `/.env` 같은 미정의 경로는 404가 유지된다.

```powershell
# 관찰 → tfvars 제안까지 자동 출력
cd ..\tuning
python waf_header_stats.py --log-group aws-waf-logs-wsi2026 --region us-east-1 --hours 1
```

제안을 `terraform.tfvars`에 넣고 apply. ⚠ 리스트 변수는 **덮어쓰기**라 기본값 + 새 값을 전부
나열해야 한다.

- **오탐 의심 시**(avail% 하락): 해당 변수만 `[]` / `false`로 바꿔 apply → 즉시 해제
- 확신 없으면 `waf_custom_rule_action = "count"`로 관찰 후 `"block"` 복귀
  (count는 기본 패턴까지 전부 관찰 모드가 되니 확인 즉시 되돌릴 것)

---

## 7. 성능/비용 튜닝

```powershell
cd ..\tuning
.\loadtest.ps1 $EP 180s baseline      # 병목 앱 찾기 (perf% 낮은 앱)
.\autotune.ps1 $EP -App stress        # 그 앱만 정밀 스윕
```

우승값은 `k8s_apps.tf`의 해당 앱 `requests.cpu` / HPA `average_utilization`·`min_replicas`에 박고
apply한다 (`kubectl patch`는 재배포 시 사라짐). 상세는 [`../tuning/README.md`](../tuning/README.md).

**avail% < 99면 비용보다 무조건 용량부터.**

---

## 8. 트러블슈팅

| 증상                                                        | 처방                                                                                                                                                                    |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AlreadyExists` 409                                       | 옛 리소스 잔재. state 있는 쪽에서 destroy, 안 되면`-var project=<새이름>` 으로 새로 배포                                                                              |
| `NodeCreationFailure`                                     | state 오염으로 라우트 association이 옛 서브넷을 가리킴. 깨끗한 state면 발생 안 함                                                                                       |
| Service 생성 전부 거부 (`mservice.elbv2.k8s.aws` webhook) | `kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook` (validating도) → 재apply                                                                     |
| 애드온/helm이 FAILED로 낌                                   | `aws eks delete-addon --addon-name metrics-server ...` / `helm uninstall karpenter -n kube-system` → 재apply                                                       |
| `Unauthorized` 일시 오류                                  | 액세스 전파 타이밍 → 재apply                                                                                                                                           |
| `error during connect ... docker daemon`                  | Docker Desktop 미실행                                                                                                                                                   |
| destroy가`connectex: No connection`                       | 클러스터가 이미 없는 경우:`terraform state list \| Select-String "kubernetes_\|helm_\|kubectl_" \| ForEach-Object { terraform state rm $_.ToString().Trim() }` 후 destroy |
| 파드가 ALB 타겟에 안 붙음                                   | `kubectl -n kube-system get deploy aws-load-balancer-controller` Ready 확인 (TargetGroupBinding이 pod IP 등록)                                                        |
| 앱이 DB 인증 실패 (`1045`)                                | db-init이`mysql_native_password`로 ALTER했는지 확인: `kubectl -n app logs job/db-init`                                                                              |

### 정리 (연습 계정)

```powershell
terraform destroy -auto-approve
```

---

## 9. 파일 구조

```
terraform/
├── versions.tf / providers.tf / outputs.tf
├── variables.tf              # 경로·포트·노드·WAF 차단 패턴 — 대회날 여기만 보면 됨
├── locals.tf                 # api_paths 계산 (ALB 규칙 + WAF scope 단일 소스)
├── terraform.tfvars          # 실제 적용 중인 WAF 차단 패턴
├── vpc.tf                    # VPC + 2-AZ public subnet + IGW + S3 VPCe
├── ecr.tf / build.tf         # ECR 3개 + apply 내 docker build/push
├── rds.tf                    # MySQL 8.0 Multi-AZ + 파라미터그룹
├── rds_proxy.tf              # RDS Proxy (커넥션 풀링) + Secrets Manager + IAM/SG
├── s3.tf / seed.tf           # 이미지 버킷(OAC) + 시드 덤프 업로드
├── eks.tf                    # 클러스터 1.35 + 노드그룹 + 애드온
├── karpenter.tf              # Karpenter 1.13 + NodePool/EC2NodeClass
├── iam.tf + policies/        # IRSA + ALB controller 정책
├── lb_controller.tf          # AWS LB Controller (TargetGroupBinding용)
├── alb.tf                    # ALB + TG + 리스너 (유효경로 forward / 미정의 404 / 직접호출 403)
├── k8s_base.tf               # namespace + Secret/ConfigMap + db-init Job
├── k8s_apps.tf               # user/product/stress Deploy+Svc+HPA  ← 튜닝값 반영처
├── waf.tf                    # WAFv2 (변수로만 제어 — 수정할 일 없음)
└── cloudfront.tf             # 단일 엔드포인트 + 캐싱 + /images rewrite
```
