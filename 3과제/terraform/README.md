# wsi-2026-task3 — Infrastructure

2026 전국기능경기대회 클라우드컴퓨팅 3과제 (System Operation) 인프라.

## 구성

| 계층 | 리소스 | 비고 |
|---|---|---|
| 네트워크 | VPC + 2-AZ public subnet (a/b) | NAT 없음, 단일 RT, IGW만 |
| 컨테이너 | EKS 1.35 + EC2 t3.medium 2~4대 node group | Fargate/Lambda 금지 준수 |
| 오토스케일 | Karpenter 1.13 (노드) + HPA (파드) | 부하 시 t3.medium 추가 프로비저닝 |
| 레지스트리 | ECR × 3 (user/product/stress) | terraform apply 시 docker build로 자동 push |
| DB | RDS MySQL 8.0 db.t3.micro Multi-AZ gp3 | identifier `apdev-rds-instance` |
| 스토리지 | S3 (private, CloudFront OAC) | 이미지 버킷 |
| 엔드포인트 | CloudFront → ALB + S3 | 단일 엔드포인트 |
| 부하분산 | 네이티브 ALB + AWS LB Controller 3.4 (TargetGroupBinding) | pod IP 타겟 등록 |
| 보안 | WAFv2 (Common/KnownBadInputs/SQLi) | 비정상 요청 403 차단 |

> **실행 환경: AWS CloudShell (Amazon Linux 2023, 서울 `ap-northeast-2`)** 기준.
> 필요한 도구는 CloudShell에 모두 내장(terraform, aws CLI, docker, kubectl). 별도 설치 불필요.

## 효율성 설계 (채점기준 반영)

채점 12점 = **비용 ratio** + 12점 = **성능 (≤0.2s 비율)** + 12점 = **가용성** + 4점 = **비정상 요청 처리**.

### 비용 최적화 (12점)
- NAT Gateway 제거 → 월 $32+ 절감
- t3.medium 노드 2~4대 HPA + Karpenter (필요 시만 확장, idle 시 consolidation)
- 단일 NAT/Private subnet 제거로 단순화
- ECR 라이프사이클 10개

### 성능 효율성 (12점, 0.2s 이하)
- **product GET 캐싱**: 앱 `sync.Map` (10s TTL) + CloudFront 캐시 (querystring `id` 기준)
  - 같은 id 반복 요청 → DB hit 안 함 (사실상 0.001s 응답)
- **user.email 인덱스**: 스펙에 없는 인덱스를 db-init Job이 자동 추가
- **HPA**: CPU 55~60% 기준 자동 확장
- **CloudFront `/images/*`**: S3 직접 캐싱 (앱 우회)

### 가용성 (12점)
- EKS node 2-AZ
- RDS Multi-AZ
- topology spread constraint로 pod 분산

### 비정상 요청 (4점)
- WAFv2 AWS Managed Rules → 403
- 정의 안 된 path → ALB fixed-response 404

---

## 환경 준비 — 설치 & 클론 (CloudShell)

CloudShell엔 aws CLI·docker·kubectl·git은 내장이지만 **terraform은 없으니** 설치해야 합니다.

```bash
# 1) terraform 설치 (HashiCorp repo, 최신 버전 / AL2023)
sudo dnf install -y dnf-plugins-core && sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo && sudo dnf install -y terraform && terraform -version
```

```bash
# 2) 저장소 클론 (사설 repo → 토큰 사용 / 공개면 토큰 없이)
git clone https://<GITHUB_TOKEN>@github.com/gmst-cc/wsi-2026-task3.git ~/wsi-2026-task3
```

```bash
# 3) 자격증명 확인 (CloudShell은 콘솔 계정으로 자동 인증)
aws sts get-caller-identity
```

> `dnf` 설치분은 루트 영역(임시)이라 CloudShell 세션이 재시작되면 사라집니다. 새 세션이면 1) 만 다시 실행하세요.

---

## 사전 준비 — CloudShell 용량 문제 (필수)

CloudShell의 홈 디렉터리(`$HOME = /home/cloudshell-user`)는 **영구 스토리지가 1GB뿐**입니다.
terraform 프로바이더(AWS 프로바이더 v5.x 하나만 ~900MB)를 기본 위치(`~/.terraform.d`, `./.terraform`)에
설치하면 **`no space left on device`** 오류로 `terraform init`이 실패합니다.

반면 루트 overlay(`/`)에는 보통 **~9GB**가 남아 있고 `/tmp`가 여기에 속합니다.
**해결: 프로바이더/캐시를 `/tmp`(overlay)로 보낸다.**

```bash
df -h $HOME /tmp   # 홈(/dev/loop0)은 1GB, overlay(/)는 ~9GB 확인
```

> ⚠️ **순서가 중요**: `export`를 **`terraform init` 보다 먼저** 해야 합니다.
> export 없이 init하면 에러 경로가 `.terraform/providers/...`(=홈)로 찍히며 다시 터집니다.

```bash
cd ~/wsi-2026-task3/terraform

# 1) (이전에 실패해 남은 캐시가 있으면) 정리 — .terraform.lock.hcl 은 지우지 말 것
rm -rf .terraform ~/.terraform.d/plugin-cache

# 2) /tmp(overlay)로 경로 지정  ← init 전에 반드시 먼저!
export TF_PLUGIN_CACHE_DIR=/tmp/tf-plugin-cache
export TF_DATA_DIR=/tmp/wsi-tf-data
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# 3) 적용됐는지 확인 (비어있으면 export가 안 된 것)
echo "TF_DATA_DIR=$TF_DATA_DIR"   # → TF_DATA_DIR=/tmp/wsi-tf-data

# 4) 이제 init
terraform init
```

- `TF_DATA_DIR`이 `.terraform`(프로바이더/모듈)을 `/tmp`로 보내므로 1GB 홈을 거의 쓰지 않습니다.
- `terraform.tfstate`는 작업 디렉터리(홈)에 그대로 남습니다. **state는 영향 없음.**
- **같은 셸에서** 이어서 `plan`/`apply`하면 export가 유지됩니다.
- `/tmp`는 **세션 재시작 시 초기화**됩니다 → CloudShell 탭을 새로 열면 위 2)·4)를 다시 실행.
- 매 세션 자동 적용하려면 `~/.bashrc`에 등록:
  ```bash
  cat >> ~/.bashrc <<'EOF'
  export TF_PLUGIN_CACHE_DIR=/tmp/tf-plugin-cache
  export TF_DATA_DIR=/tmp/wsi-tf-data
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  EOF
  ```
  (단, `.bashrc`에 넣어도 `/tmp` 내용은 세션 재시작 시 비므로 `terraform init`은 다시 해야 함)

---

## 배포

> 위 **'사전 준비'에서 `export` → `terraform init`** 까지 끝낸 상태라고 가정합니다 (같은 셸 유지).

```bash
cd ~/wsi-2026-task3/terraform
terraform apply -auto-approve            # ~20분 (EKS + RDS 동시 생성)

terraform output endpoint
# https://dXXXXX.cloudfront.net    ← 채점 플랫폼에 입력
```

> 자격증명: CloudShell은 콘솔 자격증명으로 자동 인증됩니다. 별도 프로파일이 필요하면
> `terraform apply -auto-approve -var aws_profile=<프로파일명>`.

`null_resource.build_push`가 `terraform apply` 안에서 ECR 로그인 + `docker build` + `docker push`를
자동 수행합니다. 바이너리(`application/binary/{user,product,stress}`) hash가 바뀌면 자동 재빌드됩니다.

> **CloudShell(Linux) 환경**: `build.tf`의 local-exec는 `bash`로 동작하고, ECR 로그인은
> `--password-stdin`, 이미지는 `docker build` + `docker push`를 사용합니다.
> NodePool / TargetGroupBinding 은 `kubectl_manifest`로 적용되어 별도 kubectl/셸 작업이 필요 없습니다.

---

## 대회 당일 — 앱을 새로 받았을 때 적용

대회 중 제공되는 **새 앱 바이너리**를 배포에 반영하는 절차.

### 1. 바이너리 교체
받은 실행 파일을 아래 경로에 그대로 덮어씁니다 (파일명 고정: `user`, `product`, `stress`).

```bash
cp /path/to/new/user    ~/wsi-2026-task3/application/binary/user
cp /path/to/new/product ~/wsi-2026-task3/application/binary/product
cp /path/to/new/stress  ~/wsi-2026-task3/application/binary/stress
chmod +x ~/wsi-2026-task3/application/binary/{user,product,stress}
```

### 2. 새 태그로 apply (권장)
이미지 태그를 새 값으로 바꿔 apply 하면, ECR push와 **Deployment 롤링 업데이트가 같이** 일어납니다.
(기본 태그가 `latest`로 고정이면 매니페스트가 안 바뀌어 새 이미지가 롤아웃되지 않습니다.)

```bash
cd ~/wsi-2026-task3/terraform
terraform apply -auto-approve -var app_image_tag="v$(date +%s)"
```

- 동작 흐름: 바이너리 hash 변경 → `null_resource.build_push` 재실행(빌드+push)
  → Deployment 이미지 태그 변경 → user/product/stress 파드 롤링 재배포.

### 3. 롤아웃 확인
```bash
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2   # 최초 1회
kubectl -n app rollout status deploy/user
kubectl -n app rollout status deploy/product
kubectl -n app rollout status deploy/stress
kubectl -n app get pods -o wide
```

> 같은 태그(`latest`)로 빌드만 다시 한 경우엔 매니페스트가 동일해 자동 롤아웃이 안 됩니다.
> 그럴 땐 강제로:
> ```bash
> kubectl -n app rollout restart deploy/user deploy/product deploy/stress
> ```

---

## 데이터 로드

⚠️ **RDS는 프라이빗**(`publicly_accessible=false`, SG가 VPC 내부 CIDR만 허용)이라
**CloudShell에서 직접 `mysql` 접속은 안 됩니다(연결 대기/멈춤).** VPC 안에서 도는
**임시 파드**로 덤프를 주입하세요.

```bash
cd ~/2026-terraform/3과제/terraform
export TF_DATA_DIR=/tmp/wsi-tf-data
EP=$(terraform output -raw rds_endpoint | cut -d: -f1)
PW=$(terraform output -raw db_password)

# dump 는 3과제 폴더(상위)에 있음 → ../load_user.dump
kubectl -n app run mysql-load --rm -i --restart=Never --image=mysql:8.0 -- \
  mysql -h "$EP" -u appuser -p"$PW" dev < ../load_user.dump

# 적재 확인
kubectl -n app run mysql-q --rm -i --restart=Never --image=mysql:8.0 -- \
  mysql -h "$EP" -u appuser -p"$PW" dev -e "SELECT COUNT(*) FROM user;"
```
> `kubectl` 안 잡히면 먼저: `aws eks update-kubeconfig --name <클러스터명> --region ap-northeast-2`

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

## 트러블슈팅

### 1. `no space left on device` (terraform init/플러그인 설치 실패)
CloudShell 홈 1GB 한계 → 위 **'사전 준비 — CloudShell 용량 문제'** 참고.
`export TF_DATA_DIR=/tmp/...`를 **init 전에** 했는지 확인.

### 2. `...AlreadyExists` 409 (apply 시 이름 충돌)
이전 배포 리소스가 AWS에 남아있는데 현재 state엔 없을 때 발생. state는 git에 안 올라가므로
(`*.tfstate*` ignore) **다른 PC/세션에서 apply했던 흔적**이 원인.
→ **state가 있는 쪽에서 `terraform destroy`로 먼저 밀고**, 한 곳에서만 다시 `apply`.
state가 어디에도 없다면 충돌 리소스를 콘솔/CLI로 수동 삭제 후 재시도.

> ⚠️ **state는 한 곳에서만 관리**. Windows·CloudShell 등 두 곳에서 번갈아 apply하면 409/중복이 반복됨.
> 여러 곳에서 쓰려면 S3 backend로 state 공유를 권장.

### 3. Service 생성이 전부 막힘 (가장 흔한 함정)
```
AdmissionRequestDenied: failed calling webhook "mservice.elbv2.k8s.aws":
no endpoints available for service "aws-load-balancer-webhook-service"
```
AWS LB Controller의 **Service 변형 웹훅**이 컨트롤러 Ready 전에 fail-closed가 되어
metrics-server 애드온/Karpenter 등 **모든 Service 생성을 클러스터 전역에서 차단**.
→ 코드에서 이미 `enableServiceMutatorWebhook=false`로 비활성화함 (네이티브 ALB+TGB만 쓰므로 불필요).

이미 깨진 웹훅이 클러스터에 남아 apply가 막히면, **웹훅을 먼저 지우고 재적용**:
```bash
aws eks update-kubeconfig --name wsi2026-cluster --region ap-northeast-2
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
terraform apply -auto-approve
```

### 4. 애드온/Helm이 실패 상태로 끼어 재적용이 막힐 때
```bash
# metrics-server 애드온이 CREATE_FAILED 로 남아 재생성 거부 시
aws eks delete-addon --cluster-name wsi2026-cluster --addon-name metrics-server --region ap-northeast-2
# karpenter helm 이 failed 상태일 때
helm uninstall karpenter -n kube-system
# 이후
terraform apply -auto-approve
```

### 5. `kubernetes_secret.db: Unauthorized` 등 일시적 인증 오류
클러스터 초기화/액세스 전파 타이밍 문제인 경우가 많음 → `terraform apply` 재실행 시 대개 해소.

### 6. 이름 충돌(409)이 안 풀려 빨리 새로 깔아야 할 때 — 프로젝트명 변경
state가 완전히 사라졌는데 옛 리소스가 AWS에 남아 409가 반복되면, **프로젝트명을 바꿔
전부 새 이름으로 배포**하면 충돌이 한 번에 사라집니다 (비상 탈출용).

```bash
cd ~/2026-terraform/3과제/terraform
rm -f terraform.tfstate terraform.tfstate.backup          # (깨졌거나 빈 state일 때만)
sed -i 's/default = "wsi2026"/default = "wsi2026b"/' variables.tf   # 새 프로젝트명
export TF_DATA_DIR=/tmp/wsi-tf-data
terraform init && terraform apply -auto-approve
```

⚠️ **주의**
- 옛 `wsi2026-*` 리소스는 **그대로 남아 비용 발생**(채점의 비용 ratio↑) → **채점 전 콘솔/CLI로 삭제**.
- 이건 **최후의 수단**입니다. 평소엔 **state를 안 지우고**(CloudShell 홈은 영속) 같은 폴더에서
  계속 작업하는 게 정석 — 그러면 409 자체가 안 납니다. (state가 "이미 만든 것"을 기억하므로)

### 컨트롤러 정상 동작 확인
```bash
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
# 파드 Ready 여야 TargetGroupBinding이 pod IP를 타겟그룹에 등록함
```

## 정리

```bash
terraform destroy -auto-approve
```

## 파일 구조

```
terraform/
├── versions.tf / providers.tf / variables.tf / locals.tf / outputs.tf
├── vpc.tf                       # VPC + 2-AZ public subnet + IGW + S3 VPCe
├── ecr.tf                       # 3 repos + lifecycle
├── build.tf                     # null_resource: bash docker build + ECR push (CloudShell)
├── rds.tf                       # MySQL 8.0 Multi-AZ
├── s3.tf                        # private bucket + CloudFront OAC
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
