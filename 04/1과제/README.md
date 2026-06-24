# 제1과제 (인천 v2) — Terraform

2026 전국기능경기대회 클라우드컴퓨팅 제1과제(`과제지_v2`)를 Terraform 으로 구성한다.
EKS(컨테이너) 기반 콘서트 예약 REST API + 정적 웹 + 모니터링/로깅 인프라.

> ⚠️ `terraform init` / `terraform validate` 통과 확인됨. `apply` 는 AWS 자격증명이 없는
> 작성 환경에서 실행하지 못했으므로, 실제 apply 시 **§1 의 2단계 절차**를 그대로 따르고
> **§4 의 수동 검증 항목**을 확인할 것.

---

## 0. 새 컴퓨터에서 처음 실행할 때 — 설치

필요한 도구: **terraform, aws CLI, docker(데몬 실행), kubectl, helm, git**.

### 0-A. Windows (PowerShell 관리자 권한)

winget 기준(권장). winget 이 없으면 0-C 의 choco 사용.

```powershell
# 패키지 매니저로 일괄 설치
winget install -e --id HashiCorp.Terraform
winget install -e --id Amazon.AWSCLI
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
winget install -e --id Git.Git
winget install -e --id Docker.DockerDesktop   # 설치 후 Docker Desktop 실행(데몬 켜기) 필수

# 새 PowerShell 창을 열어 PATH 반영 후 버전 확인
terraform -version; aws --version; kubectl version --client; helm version; docker version; git --version
```

### 0-B. AWS 자격증명 설정

```powershell
aws configure
#   AWS Access Key ID     : <발급키>
#   AWS Secret Access Key : <발급시크릿>
#   Default region name   : ap-northeast-2
#   Default output format : json
aws sts get-caller-identity   # 정상 출력되면 OK (Admin 권한 계정이어야 함)
```

### 0-C. Windows (choco 대안)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install -y terraform awscli kubernetes-cli kubernetes-helm git docker-desktop
```

### 0-D. Linux(예: Bastion/CloudShell 대안, Amazon Linux/dnf)

```bash
sudo dnf install -y git docker
sudo systemctl enable --now docker
# terraform
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform
# aws cli v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip -q awscliv2.zip && sudo ./aws/install
# kubectl
curl -fsSLO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/kubectl
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

- 배포파일(`files/book`, `files/index.html`, `files/main.jpeg`)은 이미 배치되어 있음.

## 1. 배포 순서 (정확한 절차)

```powershell
cd "C:\Users\competitor\2026-terraform\04\1과제"
terraform init

# [1단계] EKS 퍼블릭 엔드포인트 ON 으로 전체 생성.
#   - Windows 로컬에서 helm/kubernetes provider 가 클러스터에 접속하려면
#     apply 동안 퍼블릭 엔드포인트가 반드시 켜져 있어야 한다. (이 단계는 필수)
terraform apply -var="eks_public_access=true"

# [2단계] 채점 요건(endpointPublicAccess=False, PrivateAccess=True)으로 전환.
#   - 이 단계도 반드시 실행해야 채점 6-1-A(False True)를 통과한다.
terraform apply -var="eks_public_access=false"
```

> **이 2단계는 "필요할 수도 있는" 것이 아니라 항상 둘 다 실행해야 한다.**
> 1단계만 하면 채점(public=False) 불합격, 2단계부터 시작하면 Windows 에서
> helm/k8s 리소스 생성이 실패한다.

### 단일 apply 로 끝나는 것 (추가 apply 불필요)

- **CloudFront VPC Origin SG 규칙(`app_lb_from_cf`)** — `data.aws_security_group.cf_vpc_origin`
  이 `aws_cloudfront_vpc_origin.app_lb` 에 `depends_on` 으로 묶여 있어, Terraform 이
  데이터 조회를 **apply 시점(=VPC Origin 생성 후)** 으로 미룬다. 즉 위 1단계 apply
  한 번 안에서 SG 생성 → 조회 → 규칙 적용이 순서대로 끝난다. 별도 apply 불필요.
- **이미지 빌드(`null_resource.build_push_book`)** — apply 중 docker 로 빌드·푸시.
  **Docker 데몬이 켜져 있어야 한다.** 빌드 단계에서 인터넷으로 static curl/upx 를 받는다.

## 2. 파일 구성

| 파일 | 담당 과제 |
|---|---|
| `providers.tf` / `versions.tf` | provider, region, k8s/helm 연결 |
| `variables.tf` | **대회 중 바뀌는 값 모음** (region, azs, ssh_password, dns domain 등) |
| `locals.tf` | 리소스 이름/CIDR 등 상수 |
| `vpc.tf` | 4. VPC (서브넷6/라우팅/엔드포인트) |
| `kms.tf` | 공용 CMK |
| `bastion.tf` | 5. Bastion |
| `s3.tf` | 6. S3 |
| `ecr.tf` + `files/Dockerfile` | 7. ECR + 이미지 빌드 |
| `dynamodb.tf` | 8. DynamoDB |
| `eks.tf` | 9.1 Cluster + Addon + EBS CSI + CoreDNS(wsc.local) |
| `eks_nodegroups.tf` + `files/nodeadm.mime.tftpl` | 9.2 NodeGroup(app/addon/monitoring) |
| `k8s_app.tf` | 9.3~9.6 Deployment/ConfigMap/SA/StorageClass |
| `alb.tf` | 12.1 app-lb + LB Controller |
| `lambda.tf` + `files/lambda_function.py` | 15. Lambda |
| `cloudfront.tf` | 14. CloudFront(VPC Origin) |
| `waf.tf` | 13. WAF |
| `logging.tf` + `k8s/fluentbit-values.yaml.tftpl` | 10. Fluent Bit |
| `monitoring.tf` + `k8s/*.tftpl`, `k8s/wsc-eks-dashboard.json` | 11/12.2 Prometheus·Grafana·addon-lb |

---

## 3. 🔧 값이 바뀌면 어디를 고치나 (대회 30% 변경 대응표)

> 원칙: 가능한 값은 `variables.tf` / `locals.tf` 한 곳에서 바꾸면 전체 반영되게 했다.
> 이름·CIDR 처럼 채점이 "정확히 일치"를 보는 값은 아래 위치를 직접 수정.

### 3.1 네트워크 (VPC / Subnet / Route)

| 바뀌는 값 | 수정 위치 |
|---|---|
| VPC CIDR (`10.0.0.0/16`) | `locals.tf` → `local.vpc_cidr`. SG ingress 의 `cidr_blocks=[local.vpc_cidr]` 자동 반영 |
| 서브넷 CIDR/이름/AZ | `locals.tf` → `local.subnets` 맵 (key별 cidr/az). 이름 태그는 `vpc.tf` 의 각 `aws_subnet` `tags.Name` |
| 리전 / AZ | `variables.tf` → `region`, `azs` (a,c 순서 유지) |
| 라우팅 규칙 자체(공인/NAT/없음) | `vpc.tf` 의 `aws_route_table.*` 블록. **workload RTB 는 경로 0개 유지**(채점 1-1-C) |
| 엔드포인트 종류 추가/삭제 | `vpc.tf` → `local.interface_endpoints` 리스트 / `aws_vpc_endpoint.*_gw` |

> ⚠️ 라우팅 채점(1-1-C)이 매우 민감하다. Gateway Endpoint(S3/DynamoDB)는
> **private RTB 에만** 연결되어 있다. workload 서브넷에 붙이면 `vpce-` 경로가 생겨 0 체크가 깨진다.

### 3.2 이름 (대부분 `locals.tf` 또는 해당 리소스)

| 리소스 | 현재 값 | 수정 위치 |
|---|---|---|
| EKS Cluster | `wsc-eks-cluster` | `locals.tf` → `cluster_name` (서브넷 태그도 이 값 참조) |
| ECR repo | `wsc-repo` (tag `v1.0.0`) | `locals.tf` → `ecr_repo`, `image_url` |
| DynamoDB | `wsc-table` / PK `client_id` | `locals.tf` → `table_name`; PK 는 `dynamodb.tf` `hash_key`+`attribute` |
| S3 버킷 | `wsc-static-<ACCOUNT_ID>` | `locals.tf` → `bucket_name` |
| Node Group 이름/Label/Instance Tag | `eks_nodegroups.tf` → `local.node_groups` 맵 |
| Deployment/Container/ConfigMap | `wsc-deploy`/`wsc-cnt`/`wsc-config` | `k8s_app.tf` |
| StorageClass / PVC | `wsc-sc` / `wsc-prometheus-pvc`,`wsc-grafana-pvc` | `k8s_app.tf`, `monitoring.tf` |
| ALB(app/addon) | `wsc-app-lb` / `wsc-addon-lb` | `alb.tf` `aws_lb.app.name` / `monitoring.tf` ingress 의 `load-balancer-name` |
| CloudFront / WAF | `wsc-cdn` / `wsc-waf` | `cloudfront.tf` `tags.Name` / `waf.tf` `name` |
| Lambda | `wsc-get-table-function` / `python3.14` | `lambda.tf` `function_name`, `runtime` |
| Bastion | `wsc-bastion` | `bastion.tf` `aws_instance.bastion.tags.Name` |

### 3.3 자주 바뀌는 설정 값

| 바뀌는 값 | 수정 위치 |
|---|---|
| SSH 패스워드 (`Skill53##`) | `variables.tf` → `ssh_password` (Bastion·노드·Grafana admin 공통 반영) |
| 클러스터 DNS 도메인 (`wsc.local`) | `variables.tf` → `cluster_dns_domain` **+** `eks.tf` CoreDNS `corefile` 의 `kubernetes wsc.local ...` 줄 (채점 6-6 이 문자열을 직접 grep 하므로 둘 다 수정) |
| EKS 버전 (`1.35`) | `eks.tf` `aws_eks_cluster.version` |
| 노드 Instance Type (`t3.medium`) | `eks_nodegroups.tf` 각 `aws_eks_node_group.instance_types` |
| Bastion Instance Type (`t3.medium`) | `bastion.tf` `instance_type` |
| 이미지 태그 (`v1.0.0`) | `locals.tf` `image_url` + `k8s_app.tf` Deployment image |
| WAF 차단 문자열 (`admin`,`sysop`) | `waf.tf` 각 rule 의 `search_string` |
| Grafana datasource URL | `monitoring.tf` `ds_url` (도메인은 `cluster_dns_domain` 자동) |
| 대시보드 패널/쿼리 | `k8s/wsc-eks-dashboard.json` |
| Lambda API 응답/404 메시지 | `files/lambda_function.py` |
| 정적 웹 내용 | `files/index.html`, `files/main.jpeg` (배포파일 그대로) |
| ALB 미정의경로 404 본문(`Contents Not Found`) | `alb.tf` `aws_lb_listener.app` default_action |

---

## 4. apply 후 반드시 검증할 항목 (untested, 채점 위험 구간)

아래는 환경상 자동 검증이 불가해 **수동 확인/조정**이 필요한 부분이다.

1. **EKS 퍼블릭 차단** — 최종 `endpoint_public_access=false`. 채점은 Bastion 에서 kubectl.
   apply 2단계 후 `aws eks describe-cluster ... endpointPublicAccess` 가 False 인지 확인.
2. **app-lb 직접 접근 차단(7-1-B)** — `app_lb_from_cf` 규칙으로 CloudFront VPC Origin SG 만
   허용. Bastion 에서 `curl http://<app-lb-dns>/health` 가 **timeout** 이어야 정답.
3. **워크로드 노드 S3 도달** — workload RTB 경로 0 제약 때문에 ECR 레이어(S3)는
   S3 **Interface** Endpoint 로 받는다. 노드가 이미지 pull 실패하면 `aws_vpc_endpoint.interface["s3"]`
   private DNS 동작을 확인.
4. **이미지 크기 8MB(5-2) & 취약점 0** — `files/Dockerfile`(scratch+upx+static curl) 빌드 후
   `aws ecr describe-images` 로 크기 확인. 초과 시 base 조정.
5. **노드 hostname / wsc.local / SSH password** — nodeadm MIME(`files/nodeadm.mime.tftpl`)로 설정.
   채점 6-2/6-4/6-6 을 Bastion 에서 직접 확인.
6. **Fluent Bit /health 제외(12-1)** — `k8s/fluentbit-values.yaml.tftpl` 의 grep Exclude.
   실제 로그 필드명(`log`)과 맞는지 확인.
7. **Grafana 대시보드 PromQL 값(11-2)** — `wsc-eks-dashboard.json` 의 각 쿼리 결과 개수가
   채점 기대값(노드 6, app pod 2)과 맞는지 확인. metric 라벨(instance/node)이 다르면 조정.
8. **CloudFront VPC Origin** — 신규 기능. provider 버전(aws ~>6)에서 `aws_cloudfront_vpc_origin`
   생성/연결이 정상인지 확인.
