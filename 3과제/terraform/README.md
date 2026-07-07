# wsi-2026-task3 — Infrastructure

2026 전국기능경기대회 클라우드컴퓨팅 3과제 (System Operation) 인프라.

## 구성

| 계층 | 리소스 | 비고 |
|------|--------|------|
| 네트워크 | VPC + 2-AZ public subnet (a/b) | NAT 없음, 단일 RT, IGW만 |
| 컨테이너 | EKS 1.35 + EC2 t3.medium 2~4대 node group | Fargate/Lambda 금지 준수 |
| 오토스케일 | Karpenter 1.13 (노드) + HPA (파드) | 부하 시 t3.medium 추가 프로비저닝 |
| 레지스트리 | ECR × 3 (user/product/stress) | terraform apply 시 docker build로 자동 push |
| DB | RDS MySQL 8.0 db.t3.micro Multi-AZ gp3 | identifier `apdev-rds-instance` |
| 스토리지 | S3 (private, CloudFront OAC) | 이미지 버킷 |
| 엔드포인트 | CloudFront → ALB + S3 | 단일 엔드포인트 |
| 부하분산 | 네이티브 ALB + AWS LB Controller 3.4 (TargetGroupBinding) | pod IP 타겟 등록 |
| 보안 | WAFv2 (Common/KnownBadInputs/SQLi) | 비정상 요청 403 차단 |

> **실행 환경: Windows PowerShell (`ap-northeast-2`)** 기준. Docker Desktop + Terraform + AWS CLI + kubectl이 필요합니다.

## 효율성 설계 (채점기준 반영)

채점 12점 = **비용 ratio** + 12점 = **성능 (≤0.2s 비율)** + 12점 = **가용성** + 4점 = **비정상 요청 처리**.

### 비용 최적화 (12점)
* NAT Gateway 제거 → 월 $32+ 절감
* t3.medium 노드 2~4대 HPA + Karpenter (필요 시만 확장, idle 시 consolidation)
* 단일 NAT/Private subnet 제거로 단순화
* ECR 라이프사이클 10개

### 성능 효율성 (12점, 0.2s 이하)
* **product GET 캐싱**: 앱 `sync.Map` (10s TTL) + CloudFront 캐시 (querystring `id` 기준)
  * 같은 id 반복 요청 → DB hit 안 함 (사실상 0.001s 응답)
* **user.email 인덱스**: 스펙에 없는 인덱스를 db-init Job이 자동 추가
* **HPA**: CPU 55~60% 기준 자동 확장
* **CloudFront `/images/*`**: S3 직접 캐싱 (앱 우회)

### 가용성 (12점)
* EKS node 2-AZ
* RDS Multi-AZ
* topology spread constraint로 pod 분산

### 비정상 요청 (4점)
* WAFv2 AWS Managed Rules → 403
* 정의 안 된 path → ALB fixed-response 404

## 환경 준비 — 설치 (Windows PowerShell)

### 1. 필수 도구 설치 (관리자 권한 PowerShell)

```powershell
winget install --id Hashicorp.Terraform -e
winget install --id Amazon.AWSCLI -e
winget install --id Docker.DockerDesktop -e
winget install --id Kubernetes.kubectl -e
```

> 설치 후 **PowerShell 창을 새로 열어야** PATH가 반영됩니다.
> Docker Desktop은 설치 후 **앱을 실행**해 고래 아이콘이 "running" 상태가 되어야 합니다.

### 2. 설치 확인

```powershell
terraform -version
aws --version
docker version          # Server 항목까지 나와야 함(데몬 실행 중)
kubectl version --client
```

`docker version`에 Server가 안 나오면 Docker Desktop이 안 떠 있는 것 → 실행 후 재시도.

### 3. AWS 자격증명 설정

```powershell
aws configure
# AWS Access Key ID / Secret / region(ap-northeast-2) / output(json) 입력
aws sts get-caller-identity     # 계정 확인
```

> 명명 프로파일을 쓰면 apply 시 `-var aws_profile=<이름>`을 붙입니다.

### 4. 저장소 클론

```powershell
git clone https://github.com/hnmly/2026-0621-jaemu-task3.git
cd 2026-0621-jaemu-task3\terraform
```

## 배포 (Windows PowerShell)

kubernetes/helm provider는 EKS 클러스터가 존재해야 초기화되므로, **EKS를 먼저 만든 뒤 전체 apply** 하는 2단계로 진행합니다.

```powershell
cd C:\Users\competitor\2026-0621-jaemu-task3\terraform

terraform init

# 1단계: 네트워크 + EKS 클러스터 + 노드그룹 먼저 (~15분)
terraform apply -auto-approve "-target=aws_eks_node_group.main"

# 2단계: kubeconfig 갱신
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2

# 3단계: 나머지 전체 (앱/ALB/CloudFront/WAF 등)
terraform apply -auto-approve -var "k8s_provider_ready=true"

terraform output endpoint
# http://dXXXXX.cloudfront.net    ← 채점 플랫폼에 입력
```

> `-target=aws_eks_node_group.main` 하나면 VPC·서브넷·라우트·IGW·EKS 클러스터까지 의존성으로 함께 생성됩니다 (노드그룹이 그것들에 `depends_on` 되어 있음). 따라서 노드가 뜰 때 인터넷 라우트가 반드시 준비되어 있어 `NodeCreationFailure` 가 발생하지 않습니다.

`null_resource.build_push`가 `terraform apply` 안에서 ECR 로그인 + `docker build` + `docker push`를 자동 수행합니다. 바이너리(`application/binary/{user,product,stress}`) hash가 바뀌면 자동 재빌드됩니다.

> **Windows PowerShell 환경**: `build.tf`의 local-exec는 `powershell -NoProfile -Command`로 동작하고, ECR 로그인은 `docker login --username AWS --password (aws ecr get-login-password ...)` 형태를 사용합니다. NodePool / TargetGroupBinding 은 `kubectl_manifest`로 적용되어 별도 kubectl/셸 작업이 필요 없습니다.

## 대회 당일 — 앱(바이너리)이 바뀌었을 때 적용

대회 중 **새 앱 바이너리**가 제공되면 아래 순서로 반영합니다. 배포에 실제로 쓰이는 건 소스(`.go`)가 아니라 **`application/binary/{user,product,stress}`** 입니다 (`build.tf`가 이 바이너리만 ECR 이미지로 빌드·push).

### 1. 바이너리 교체 (파일명 고정: `user`, `product`, `stress`)

```powershell
# 예: jaemoohong 저장소에서 받는 경우
git clone --depth 1 https://github.com/jaemoohong/user.git C:\temp\userrepo
Copy-Item C:\temp\userrepo\user    .\application\binary\user    -Force
Copy-Item C:\temp\userrepo\product .\application\binary\product -Force
Copy-Item C:\temp\userrepo\stress  .\application\binary\stress  -Force

# 또는 파일로 직접 받은 경우:
Copy-Item C:\path\to\new\user    .\application\binary\user -Force
```

> 실행권한(`chmod +x`)은 **불필요**합니다 — Dockerfile이 `COPY --chmod=0755`로 이미지 안에서 권한을 부여합니다 (Windows에서도 OK).

교체 확인:
```powershell
(Get-FileHash .\application\binary\user -Algorithm SHA256).Hash
```

### 2. 새 태그로 apply (반드시 태그 변경)

이미지 태그를 **새 값으로** 바꿔 apply 해야 ECR push + Deployment 롤링 업데이트가 같이 일어납니다.

```powershell
cd 2026-0621-jaemu-task3\terraform
terraform apply -auto-approve -var app_image_tag="v$([int](Get-Date -UFormat %s))"
```

* 동작 흐름: 바이너리 hash 변경 → `null_resource.build_push` 재실행(빌드+push) → Deployment 이미지 태그 변경 → user/product/stress 파드 롤링 재배포.
* ⚠️ **Docker Desktop 실행 중**이어야 합니다.

### 3. 롤아웃 확인

```powershell
aws eks update-kubeconfig --name wsi2026e-cluster --region ap-northeast-2
kubectl -n app rollout status deploy/user
kubectl -n app rollout status deploy/product
kubectl -n app rollout status deploy/stress
kubectl -n app get pods -o wide
```

> 같은 태그(`latest`)로 빌드만 다시 한 경우엔 매니페스트가 동일해 자동 롤아웃이 안 됩니다.
> 강제 롤아웃: `kubectl -n app rollout restart deploy/user deploy/product deploy/stress`

### 4. 동작 검증 (교체 후 빠른 스모크 테스트)

```powershell
$EP = (terraform output -raw endpoint)
Invoke-RestMethod "$EP/healthcheck"                                # {"ok":true}
Invoke-RestMethod "$EP/v1/product?id=dbdump1&requestid=1&uuid=1"   # 200 or 404
```

## 검증된 동작

```
GET  /healthcheck                       → 200 {"ok":true}
POST /v1/user        {requestid,...}    → 201
GET  /v1/user?email=...&requestid=...   → 200 / 404
POST /v1/product     {id,name,price}    → 201
GET  /v1/product?id=...                 → 200 (2nd call cached, X-Cache: Hit)
PUT  /v1/product     multipart(id,image) → 200 (S3 upload)
GET  /images/foo.jpg                    → 200 (CloudFront → S3, URI rewrite)
POST /v1/stress      {length:N}         → 201
GET  /v1/none                           → 404
GET  /random                            → 404
```

## 데이터 로드

✅ **`terraform apply`가 자동으로 적재합니다.** `db-init` Job이 S3에서 시드 덤프를 받아 테이블 생성 후 적재합니다. **user 테이블이 비어 있을 때만** 적재하므로 Job 재시도·재apply에도 PK 중복이 안 납니다.

적재 확인:
```powershell
aws eks update-kubeconfig --name wsi2026e-cluster --region ap-northeast-2
kubectl -n app logs job/db-init        # "seed load done" 또는 "skipping seed"
```

## 문제 변경 대응 (당일 ±30% 변경 대비)

### DB 관련

| 문제지 변경 | 고칠 곳 | 비고 |
|------------|---------|------|
| **RDS identifier 변경** | `rds.tf` `identifier` + `tags.Name` | 덤프는 영향 없음 |
| **스키마(DB)명 변경** (`dev` → 다른) | ① `variables.tf` `db_name` ② `load_user.dump` 첫 줄 `USE` | ⚠️ 둘 다 바꿔야 함 |
| **DB 사용자/비번 변경** | `variables.tf` `db_username` | Secret 자동 반영 |
| **테이블 스키마 변경** | `k8s_base.tf` db-init Job의 `CREATE TABLE` | 인덱스 추가 등 |
| **시드 덤프 교체** | `load_user.dump` 덮어쓰기 | S3 통해 자동 적재 |
| **인스턴스 클래스 변경** | `rds.tf` `instance_class`/`allocated_storage` | |
| **Multi-AZ 변경** | `rds.tf` `multi_az` | |

### 앱 / 엔드포인트 관련

| 문제지 변경 | 고칠 곳 | 비고 |
|------------|---------|------|
| **새 앱 바이너리** | `application/binary/` 덮어쓰기 + apply with 새 태그 | "대회 당일" 섹션 참고 |
| **컨테이너 포트 변경** | `k8s_apps.tf` + `alb.tf` target group `port` | 세 곳 모두 일치 |
| **새 환경변수 요구** | `k8s_base.tf` ConfigMap/Secret → `k8s_apps.tf` env | |
| **이미지 경로 변경** | `cloudfront.tf` URI-rewrite function + path pattern | |
| **S3 버킷 이름 지정** | `s3.tf` `aws_s3_bucket.images.bucket` | |
| **비정상 요청 응답코드 변경** | `waf.tf` (403) / `alb.tf` default (404) | |

### 앱 입력/출력(스펙)이 바뀌었을 때

대회 중 새 앱 바이너리가 오면 **요청 형식(입력)이나 응답(출력)이 바뀔 수 있습니다.** 아래를 점검·수정합니다.

**1) 요청 경로/파라미터가 바뀐 경우** (예: `/v1/user` → `/v2/user`, `email` → `mail`)
- `waf.tf`: 관리형 룰의 `scope_down_statement` 에 있는 경로 문자열(`/v1/user`, `/v1/product`, `/v1/stress`)을 새 경로로 변경. (안 바꾸면 새 경로에 WAF 미적용 → 비정상 요청이 안 막힘)
- `alb.tf`: 리스너 규칙에서 유효 경로 매칭을 쓰면 그 경로도 변경.
- `cloudfront.tf`: 캐시 동작(cache behavior)의 path pattern(`/v1/product*`, `/images/*` 등)이 경로 기반이면 변경.
- `부하/app.js`: 부하 도구의 `testUser`/`testProduct`/`testStress` 의 URL·파라미터도 새 스펙으로 변경.

**2) 요청 body 필드가 바뀐 경우** (예: `length` → `size`)
- 앱이 알아서 처리하므로 인프라 수정은 대부분 불필요.
- 단 `부하/app.js` 의 POST body(`JSON.stringify({...})`)를 새 필드명으로 맞춰야 부하 테스트가 성공.
- db-init 시드가 새 컬럼을 요구하면 `k8s_base.tf` 의 `CREATE TABLE` 도 변경.

**3) 응답 코드가 바뀐 경우** (예: POST 성공이 201 → 200)
- 인프라 수정 불필요. `부하/app.js` 의 성공 판정(`status >= 200 && status < 300`)은 이미 2xx 전체를 성공으로 보므로 대부분 그대로 동작.
- 특정 코드로 판정해야 하면 `부하/app.js` `sendRequest` 의 성공 조건 수정.

**4) 새 환경변수를 앱이 요구하는 경우**
- `k8s_base.tf`: ConfigMap(`s3-config`) 또는 Secret(`db-credentials`)에 키 추가.
- `k8s_apps.tf`: 해당 Deployment 의 `env_from` 로 이미 주입되므로, 같은 Secret/ConfigMap 에 넣으면 자동 반영. 새 소스면 `env_from` 블록 추가.

**5) 포트가 바뀐 경우** (8080 → 다른 값)
- `k8s_apps.tf`: 3개 앱의 `container_port`, `readiness_probe`/`liveness_probe` 의 `port`, Service 의 `target_port`
- `alb.tf`: target group `port`
- → **총 여러 곳을 모두 같은 값으로** 맞춰야 함.

**6) 이미지 저장/다운로드 경로가 바뀐 경우**
- `cloudfront.tf`: `/images/*` URI-rewrite function 과 path pattern
- `부하/app.js`: `testImage` 의 다운로드 경로, `uploadProductImage` 의 업로드 필드

> 변경 후에는 반드시 `terraform apply -auto-approve -var "k8s_provider_ready=true"` 로 반영하고,
> `부하` 도구로 스모크 테스트하여 user/product/stress/이미지/WAF 가 정상인지 확인합니다.

### 인프라 / 리전 관련

| 문제지 변경 | 고칠 곳 | 비고 |
|------------|---------|------|
| **리전 변경** | `variables.tf` `region` + `azs` | |
| **노드 인스턴스 타입 변경** | `variables.tf` `node_instance_type` + `karpenter.tf` | |
| **EKS 버전 지정** | `variables.tf` `eks_version` | |
| **노드 수 / 오토스케일** | `variables.tf` `node_*_size` + `k8s_apps.tf` HPA | |
| **이름 충돌(409) / 새 배포** | `variables.tf` `project` 변경 | 모든 리소스 새 이름 |

> **변경 시 자주 놓치는 연쇄 의존**:
> * 스키마명(`dev`) 변경 → **덤프의 `USE` 문**도 같이
> * 포트 변경 → Deployment·probe·Service·ALB TG **4곳** 모두
> * 엔드포인트 경로 변경 → ALB·WAF·CloudFront 중 **해당 계층** 확인

## 트러블슈팅

### 1. `AlreadyExists` 409 (apply 시 이름 충돌)

이전 배포 리소스가 AWS에 남아있는데 현재 state엔 없을 때 발생. state는 git에 안 올라가므로 **다른 PC/세션에서 apply했던 흔적**이 원인.

```powershell
# state가 있는 쪽에서 먼저 destroy
terraform destroy -auto-approve -var "k8s_provider_ready=true"
# 또는 project명 변경으로 우회
# variables.tf의 project를 "wsi2026x" 등으로 변경 후 apply
```

### 2. `NodeCreationFailure` (노드가 클러스터에 조인 실패)

```
NodeGroup ... NodeCreationFailure: Instances failed to join the kubernetes cluster
```

노드가 EC2 API / EKS 엔드포인트에 접근 못 해서 발생. 노드 부팅 로그(`aws ec2 get-console-output --instance-id i-xxx`)에 `EC2/DescribeInstances retrying` 가 반복되면 **인터넷 라우트 없음**이 원인.

원인 대부분은 **state 오염**: route table association이 실제 서브넷이 아닌 옛 배포 서브넷을 가리킴. 확인:

```powershell
# 노드 서브넷에 0.0.0.0/0 → IGW 라우트가 있는지 확인
aws ec2 describe-route-tables --region ap-northeast-2 --filters "Name=association.subnet-id,Values=<노드-서브넷ID>" --query "RouteTables[0].Routes[]" --output table
```

라우트가 없으면(association이 딴 서브넷을 가리킴):

```powershell
# 잘못된 association 제거 후 재생성
terraform state rm 'aws_route_table_association.public[0]' 'aws_route_table_association.public[1]'
terraform apply -auto-approve "-target=aws_route_table_association.public"
# 실패한 노드그룹 삭제 후 재생성
aws eks delete-nodegroup --cluster-name wsi2026-cluster --nodegroup-name wsi2026-ng --region ap-northeast-2
terraform state rm aws_eks_node_group.main
terraform apply -auto-approve "-target=aws_eks_node_group.main"
```

> 코드에는 노드그룹이 route association + IGW 생성 후에 뜨도록 `depends_on`이 걸려 있어, **깨끗한 state(새 계정/새 PC)에서는 이 문제가 발생하지 않습니다.** 위 절차는 state가 오염됐을 때만 필요.

### 3. Service 생성이 전부 막힘 (웹훅 문제)

```
AdmissionRequestDenied: failed calling webhook "mservice.elbv2.k8s.aws"
```

AWS LB Controller의 Service 변형 웹훅이 Ready 전에 fail-closed → 모든 Service 생성 차단. 코드에서 이미 `enableServiceMutatorWebhook=false`로 비활성화했지만, 이미 깨진 웹훅이 남아있으면:

```powershell
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
terraform apply -auto-approve -var "k8s_provider_ready=true"
```

### 4. 애드온/Helm이 실패 상태로 끼어 재적용이 막힐 때

```powershell
# metrics-server 애드온이 CREATE_FAILED 로 남아 재생성 거부 시
aws eks delete-addon --cluster-name wsi2026-cluster --addon-name metrics-server --region ap-northeast-2
# karpenter helm 이 failed 상태일 때
helm uninstall karpenter -n kube-system
# 이후
terraform apply -auto-approve -var "k8s_provider_ready=true"
```

### 5. `Unauthorized` 등 일시적 인증 오류

클러스터 초기화/액세스 전파 타이밍 문제 → `terraform apply` 재실행 시 대개 해소.

### 6. 이름 충돌이 안 풀릴 때 — 프로젝트명 변경 (비상 탈출)

```powershell
Remove-Item terraform.tfstate, terraform.tfstate.backup -ErrorAction SilentlyContinue
# variables.tf 열어서 project = "wsi2026" → "wsi2026x" 변경
terraform init
terraform apply -auto-approve -var "k8s_provider_ready=true"
```

⚠️ 옛 `wsi2026e-*` 리소스는 **그대로 남아 비용 발생** → 채점 전 콘솔/CLI로 삭제.

### Windows에서 흔한 함정

| 증상 | 원인 / 해결 |
|------|-------------|
| `error during connect ... docker daemon` | Docker Desktop 미실행 → 실행 후 `docker version`에 Server 확인 |
| `terraform init` 후 lock 파일 에러 | 이전 `.terraform` 폴더 삭제: `Remove-Item .terraform -Recurse -Force` |
| 줄바꿈(CRLF) 때문에 스크립트 깨짐 | `application/binary/*`는 바이너리라 무관 |
| state 충돌 | 한 환경에서만 작업하거나 S3 backend 사용 |

### 컨트롤러 정상 동작 확인

```powershell
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
# 파드 Ready 여야 TargetGroupBinding이 pod IP를 타겟그룹에 등록함
```

## 정리

destroy 할 때도 **`-var "k8s_provider_ready=true"`** 를 붙여야 합니다. (안 붙이면 kubernetes/helm provider 가 `https://localhost` 를 가리켜 `connectex: No connection` 에러 발생)

```powershell
terraform destroy -auto-approve -var "k8s_provider_ready=true"
```

> 이미 클러스터가 지워져 연결이 안 되는데 k8s 리소스가 state 에 남아 destroy 가 막히면:
> ```powershell
> # k8s/helm/kubectl 리소스를 state 에서 제거 후 나머지 destroy
> terraform state list | Select-String "kubernetes_|helm_|kubectl_" | ForEach-Object { terraform state rm $_.ToString().Trim() }
> terraform destroy -auto-approve -var "k8s_provider_ready=true"
> ```

## 파일 구조

```
terraform/
├── versions.tf / providers.tf / variables.tf / locals.tf / outputs.tf
├── vpc.tf                       # VPC + 2-AZ public subnet + IGW + S3 VPCe
├── ecr.tf                       # 3 repos + lifecycle
├── build.tf                     # null_resource: PowerShell(기본) 또는 bash로 docker build + ECR push
├── rds.tf                       # MySQL 8.0 Multi-AZ
├── rds_proxy.tf                 # RDS Proxy 커넥션 풀링
├── s3.tf                        # private bucket + CloudFront OAC
├── seed.tf                      # 시드 덤프 S3 업로드 + IRSA
├── eks.tf                       # cluster(1.35) + node group + addons
├── karpenter.tf                 # Karpenter 1.13 (NodePool/EC2NodeClass)
├── iam.tf + policies/           # IRSA roles + ALB controller IAM policy(v3.4.0)
├── lb_controller.tf             # AWS LB Controller 3.4 (helm) + TargetGroupBinding
├── alb.tf                       # 네이티브 ALB + target group + listener rule (default 404)
├── k8s_base.tf                  # namespace + secret + db-init Job
├── k8s_apps.tf                  # user/product/stress Deploy+Svc+HPA
├── waf.tf                       # WAFv2 web ACL
├── cloudfront.tf                # CloudFront + URI rewrite function
└── README.md
```
