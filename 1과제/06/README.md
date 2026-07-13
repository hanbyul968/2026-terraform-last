> # 🚀 배포 방법 (2단계 — 이 안내가 최신/정답)
> **로컬에서 bastion 만 띄우고, bastion(Linux) 안에서 main 을 apply** 합니다(로컬 직접 apply 불가).
> ```powershell
> cd C:\Users\competitor\2026-terraform\1과제\06\bastion
> terraform init; terraform apply -auto-approve
> terraform output -raw ssm_connect_command
> ```
> ```bash
> until [ -f /opt/task1/READY ]; do sleep 5; done
> cd /opt/task1 && bash run.sh 2>&1 | tee /tmp/apply.log
> ```
> ⚠️ default VPC 없음 → `bastion/main.tf` 를 전용 VPC 로 교체 필요(01 참고). 아래 본문의 "로컬 PC terraform apply → EC2 bastion" 설명은 구버전입니다.


# 1과제 실행 가이드

## 전체 흐름

```
1. (로컬 PC) terraform apply   →  AWS 인프라 + EC2 bastion 생성
2. (Bastion EC2) bash setup.sh →  EKS 앱 배포 완료
3. (채점) CloudShell에서 채점 스크립트 실행
```

---

## Step 1 — 로컬 PC에서 Terraform 실행

### 1-1. 사전 확인

- `terraform`, `docker`, `aws` CLI, `kubectl` 이 PATH에 있어야 합니다.
- AWS 자격증명이 설정되어 있어야 합니다 (`aws configure` 또는 환경변수).

### 1-2. 파일 구조 확인

```
1과제/
├── static/
│   ├── index.html          ← 지급파일에서 복사
│   └── main.jpeg           ← 지급파일에서 복사
├── application/
│   ├── Dockerfile
│   └── book-linux-amd64_v1.0.1
├── k8s/
│   ├── namespace.yaml
│   ├── book.yaml
│   ├── ingress.yaml
│   ├── network-policy.yaml
│   ├── grafana.yaml
│   ├── grafana-values.yaml
│   └── fluentbit.yaml
├── bootstrap-container/
│   ├── Dockerfile
│   └── bootstrap.sh
├── lambda_function.py
└── (terraform .tf 파일들)
```

### 1-3. Terraform 실행

```powershell
cd C:\Users\competitor\2026-terraform\1과제\06

terraform init

terraform apply -var="bi_number=<비번호>"
# 예: terraform apply -var="bi_number=042"
```

- **약 15~20분** 소요 (EKS 클러스터 생성이 가장 오래 걸림)
- bootstrap 컨테이너 이미지를 자동으로 빌드 후 ECR에 푸시합니다.
- apply 완료 시 outputs에 **Bastion EC2 Public IP**가 출력됩니다.

### 1-4. Terraform 출력 확인

```powershell
terraform output
```

---

## Step 2 — Bastion EC2에서 setup.sh 실행

### 2-1. EC2 접속

```bash
# outputs에서 확인한 IP로 접속 (키 없이 SSM 사용 가능)
aws ssm start-session --target <instance-id> --region ap-northeast-2

# 또는 SSH (키페어 있을 경우)
ssh ec2-user@<bastion-public-ip>
```

### 2-2. setup.sh 실행

```bash
bash /home/ec2-user/setup.sh
```

setup.sh가 순서대로 수행하는 작업:

| 단계 | 내용 |
|------|------|
| 1 | EKS kubeconfig 업데이트 |
| 2 | book 앱 이미지 빌드 & ECR push |
| 3 | 노드 4개 Ready 대기 |
| 4 | kubelet CSR 승인 |
| 5 | grafana / fluent-bit / LBC / nginx 이미지 ECR push |
| 6 | Namespace 생성 |
| 7 | AWS Load Balancer Controller Helm 설치 |
| 8 | book 앱 배포 (Deployment + Service + TGB + NetworkPolicy) |
| 9 | Grafana ServiceAccount(IRSA) 생성 후 Helm 설치 |
| 10 | Fluent Bit DaemonSet 배포 |

- **약 10~15분** 소요
- 완료 후 `kubectl get pods -A` 로 모든 Pod가 Running인지 확인

### 2-3. 완료 확인

```bash
# 모든 Pod Running 확인
kubectl get pods -A

# 노드 이름 확인 (gj2026.<id>.addon.node / gj2026.<id>.app.node)
kubectl get nodes

# CloudFront 도메인 확인
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='gj2026-cdn'].DomainName" \
  --output text --region ap-northeast-2
```

---

## Step 3 — 채점 전 최종 점검

```bash
# CloudShell에서
CF_DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='gj2026-cdn'].DomainName" \
  --output text)
BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'gj2026-static-')].Name" --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "CF: $CF_DOMAIN"
echo "BUCKET: $BUCKET"

# book API 동작 확인
curl -X POST -H "Content-Type: application/json" \
  -d '{"client_id":"C001","username":"Alice","email":"a@a.com","concert_name":"Test"}' \
  https://$CF_DOMAIN/v1/book

# 예약 조회
curl https://$CF_DOMAIN/reservation
curl "https://$CF_DOMAIN/reservation?client_id=C001"

# Grafana 접속
echo "https://$CF_DOMAIN/grafana"
# admin / Skills53#
```

### 3-1. 채점 직전 DynamoDB 비우기 (필수)

스펙: "채점 전에 어떠한 데이터 항목이 있어도 안됩니다."
동작 확인용 POST나 직전 채점 실행으로 쌓인 데이터를 비운다.

```bash
bash clean-books.sh
# 마지막 줄이 "남은 항목 수: 0" 이어야 함
```

> 채점 중 nginx-test(NetworkPolicy 4-5) 파드가 skills 네임스페이스에 남아 있으면
> 다음 채점 실행의 `kubectl run nginx-test` 가 실패하므로 함께 정리:
> `kubectl delete pod nginx-test -n skills --ignore-not-found`

---

## 주의사항

- `terraform destroy` 시 EKS 노드그룹, ECR 이미지, S3 객체가 모두 삭제됩니다.
- 채점 전 DynamoDB 테이블에 데이터가 없어야 합니다 → `bash clean-books.sh` (setup.sh는 데이터를 건드리지 않음).
- `bi_number` 는 S3 버킷 이름(`gj2026-static-<비번호>`)에 사용됩니다. mark.sh 의 `<비번호>` 도 동일 값으로 채워야 6·8·9번이 채점됩니다.

---

## 대회 당일 30% 변경 대응 가이드

아래 항목이 바뀌면 해당 파일의 해당 위치만 수정하면 됩니다.

---

### 1. VPC / 네트워크 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| VPC CIDR (`10.0.0.0/16`) | `main.tf` | `aws_vpc.vpc` → `cidr_block` |
| VPC 이름 (`gj2026-vpc`) | `main.tf` | `aws_vpc.vpc` → `tags.Name` |
| Private Subnet-a CIDR (`10.0.10.0/24`) | `main.tf` | `aws_subnet.private_a` → `cidr_block` |
| Private Subnet-b CIDR (`10.0.11.0/24`) | `main.tf` | `aws_subnet.private_b` → `cidr_block` |
| Subnet-a 이름 (`gj2026-private-subnet-a`) | `main.tf` | `aws_subnet.private_a` → `tags.Name` |
| Subnet-b 이름 (`gj2026-private-subnet-b`) | `main.tf` | `aws_subnet.private_b` → `tags.Name` |
| Route Table-a 이름 (`gj2026-private-rtb-a`) | `main.tf` | `aws_route_table.private_a` → `tags.Name` |
| Route Table-b 이름 (`gj2026-private-rtb-b`) | `main.tf` | `aws_route_table.private_b` → `tags.Name` |
| IGW 이름 (`gj2026-igw`) | `main.tf` | `aws_internet_gateway.igw` → `tags.Name` |

> Subnet CIDR 변경 시 `k8s/network-policy.yaml`의 `ipBlock.cidr` 두 항목도 같이 수정 필요

---

### 2. ECR 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| Book 레포 이름 (`book`) | `ecr.tf` | `aws_ecr_repository.book` → `name` |
| Pull-through 캐시 prefix | `ecr.tf` | `aws_ecr_pull_through_cache_rule.ecr_public` → `ecr_repository_prefix` |

---

### 3. DynamoDB 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| 테이블 이름 (`books`) | `dynamodb.tf` | `aws_dynamodb_table.books` → `name` |
| Partition Key 이름 (`booking_id`) | `dynamodb.tf` | `attribute.name` / `hash_key` |
| GSI 이름 (`client_id-index`) | `dynamodb.tf` | `global_secondary_index.name` |
| GSI Partition Key (`client_id`) | `dynamodb.tf` | `global_secondary_index.hash_key` + `attribute.name` |
| DB KMS Key alias (`alias/gj2026-db-key`) | `kms.tf` | `aws_kms_alias.dynamodb` → `name` |

> 테이블 이름 변경 시 `k8s/book.yaml`의 `env[TABLE_NAME].value`도 수정 필요
> 테이블 이름 변경 시 `lambda_function.py`의 `TABLE_NAME` 기본값도 확인 (lambda.tf env 변수에서 설정)
> 테이블 이름 변경 시 `lambda.tf`의 `aws_lambda_function.reservation` → `environment.variables.TABLE_NAME`도 수정

---

### 4. EKS 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| 클러스터 이름 (`gj2026-eks-cluster`) | `eks.tf` | `aws_eks_cluster.cluster` → `name` |
| 클러스터 버전 (`1.35`) | `eks.tf` | `aws_eks_cluster.cluster` → `version` |
| EKS KMS Key alias (`alias/gj2026-eks-key`) | `kms.tf` | `aws_kms_alias.eks` → `name` |
| Addon Nodegroup 이름 (`gj2026-eks-addon-nodegroup`) | `eks.tf` | `aws_eks_node_group.addon` → `node_group_name` |
| App Nodegroup 이름 (`gj2026-eks-app-nodegroup`) | `eks.tf` | `aws_eks_node_group.app` → `node_group_name` |
| Addon 노드 인스턴스 타입 (`t3.medium`) | `eks.tf` | `aws_eks_node_group.addon` → `instance_types` |
| App 노드 인스턴스 타입 (`m5.large`) | `eks.tf` | `aws_eks_node_group.app` → `instance_types` |
| Addon 노드 EC2 태그 이름 (`gj2026-eks-addon-node`) | `eks.tf` | `aws_launch_template.addon` → `tag_specifications[*].tags.Name` |
| App 노드 EC2 태그 이름 (`gj2026-eks-app-node`) | `eks.tf` | `aws_launch_template.app` → `tag_specifications[*].tags.Name` |
| Addon 노드 네이밍 형식 (`gj2026.<id>.addon.node`) | `aws-auth.tf` + `eks.tf` | `aws-auth.tf` → `aws_auth_maproles[0].username` / `eks.tf` → `aws_launch_template.addon` user-data의 `user-data = "YWRkb24="` (base64 "addon") |
| App 노드 네이밍 형식 (`gj2026.<id>.app.node`) | `aws-auth.tf` + `eks.tf` | 동일 (base64 "app" = `"YXBw"`) |

---

### 5. ALB 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| ALB 이름 (`gj2026-alb`) | `alb.tf` | `aws_lb.alb` → `name` |
| Book Target Group 이름 (`gj2026-book-tg`) | `alb.tf` | `aws_lb_target_group.book` → `name` |
| Book Target Group 포트 (`8080`) | `alb.tf` | `aws_lb_target_group.book` → `port` |
| Grafana Target Group 이름 (`gj2026-grafana-tg`) | `alb.tf` | `aws_lb_target_group.grafana` → `name` |
| Grafana 경로 (`/grafana`) | `alb.tf` | `aws_lb_listener_rule.grafana` → `condition.path_pattern.values` |
| Health check 경로 (book: `/health`) | `alb.tf` | `aws_lb_target_group.book` → `health_check.path` |

---

### 6. S3 / 정적 호스팅 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| S3 버킷 이름 (`gj2026-static-<비번호>`) | `s3.tf` | `aws_s3_bucket.static` → `bucket` |
| S3 KMS Key alias (`alias/gj2026-s3-key`) | `kms.tf` | `aws_kms_alias.s3` → `name` |
| 업로드 파일 추가/변경 | `s3.tf` | `aws_s3_object` 리소스 추가 |

---

### 7. Lambda 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| Lambda 함수 이름 (`gj2026-book-reservation`) | `lambda.tf` | `aws_lambda_function.reservation` → `function_name` |
| Lambda Runtime (`python3.14`) | `lambda.tf` | `aws_lambda_function.reservation` → `runtime` |
| Lambda 로직 변경 | `lambda_function.py` | 직접 수정 후 `terraform apply` |
| DynamoDB 테이블 이름 (Lambda 환경변수 `TABLE_NAME`) | `lambda.tf` | `aws_lambda_function.reservation` → `environment.variables.TABLE_NAME` |

---

### 8. CloudFront 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| CloudFront 이름/comment (`gj2026-cdn`) | `cloudfront.tf` | `aws_cloudfront_distribution.cdn` → `comment` + `tags.Name` |
| VPC Origin 이름 (`gj2026-alb-origin`) | `cloudfront.tf` | `aws_cloudfront_vpc_origin.alb` → `vpc_origin_endpoint_config.name` |
| /reservation 경로 변경 | `cloudfront.tf` | `ordered_cache_behavior` (lambda) → `path_pattern` |
| /v1 경로 변경 | `cloudfront.tf` | `ordered_cache_behavior` (alb, first) → `path_pattern` |
| /grafana 경로 변경 | `cloudfront.tf` | `ordered_cache_behavior` (alb, second) → `path_pattern` |

---

### 9. WAF 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| WAF ACL 이름 (`gj2026-waf-acl`) | `waf.tf` | `aws_wafv2_web_acl.acl` → `name` |
| 차단 경로 (`/v1/book`) | `waf.tf` | rule `block-non-post-methods` → `byte_match_statement.search_string` |
| 차단 응답 메시지 (`Method Not Allowed`) | `waf.tf` | `custom_response_body[method-not-allowed]` → `content` |
| 차단 응답 코드 (`405`) | `waf.tf` | rule `block-non-post-methods` → `custom_response.response_code` |
| client_id 허용 패턴 정규식 | `waf.tf` | rule `validate-client-id` → `regex_match_statement.regex_string` |
| 403 응답 메시지 (`Access Denied`) | `waf.tf` | `custom_response_body[access-denied]` → `content` |

---

### 10. Monitoring 변경

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| Grafana Admin PW (`Skills53#`) | `k8s/grafana-values.yaml` | `adminPassword` |
| Grafana Namespace (`monitoring`) | `k8s/namespace.yaml` + `k8s/grafana.yaml` + `k8s/grafana-values.yaml` | 각 namespace 필드 |
| Grafana 대시보드 이름 (`WSI Dashboard`) | `k8s/grafana-values.yaml` | `dashboards.default.wsi-dashboard.json` → `"title"` 값 |
| CloudWatch 메트릭 Namespace (`BookReservation`) | `lambda_function.py` + `k8s/grafana-values.yaml` | `put_metric_data(Namespace=...)` / 대시보드 `namespace` |
| Fluent Bit Namespace (`logging`) | `k8s/namespace.yaml` + `k8s/fluentbit.yaml` | 각 namespace 필드 |
| Fluent Bit DaemonSet 이름 (`aws-for-fluent-bit`) | `k8s/fluentbit.yaml` | `DaemonSet.metadata.name` |
| CloudWatch Log Group (`/eks/book-svc/access`) | `k8s/fluentbit.yaml` | `[OUTPUT]` 두 블록 → `log_group_name` |
| CloudWatch Log Stream-a (`/book-svc/ap-northeast-2a`) | `k8s/fluentbit.yaml` | `[OUTPUT] Match book.az-a` → `log_stream_name` |
| CloudWatch Log Stream-b (`/book-svc/ap-northeast-2b`) | `k8s/fluentbit.yaml` | `[OUTPUT] Match book.az-b` → `log_stream_name` |
| AZ IP 대역 분기 (subnet CIDR 바뀔 때) | `k8s/fluentbit.yaml` | `[FILTER] rewrite_tag` → `Rule` 두 줄의 IP 패턴 |

---

### 앱 변경 (book)

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|---|---|---|
| Deployment 이름 (`book`) | `k8s/book.yaml` | `Deployment.metadata.name` |
| Service 이름 (`book-svc`) | `k8s/book.yaml` | `Service.metadata.name` |
| 레플리카 수 (`2`) | `k8s/book.yaml` | `Deployment.spec.replicas` |
| 앱 포트 (`8080`) | `k8s/book.yaml` | `containerPort` + `Service.spec.ports.targetPort` |
| Health check 경로 (`/health`) | `k8s/book.yaml` | `livenessProbe/readinessProbe.httpGet.path` |
| skills Namespace | `k8s/book.yaml` + `k8s/network-policy.yaml` + `k8s/namespace.yaml` | 각 namespace 필드 |

---

### 리소스 이름 prefix (`gj2026-`) 전체 변경

prefix가 `gj2026-` → 다른 값으로 바뀌면 아래를 **일괄 찾아 바꾸기**:

- `main.tf`, `eks.tf`, `alb.tf`, `cloudfront.tf`, `dynamodb.tf`, `ecr.tf`, `kms.tf`, `lambda.tf`, `s3.tf`, `waf.tf`, `aws-auth.tf` 전체에서 `gj2026` 검색 후 교체
- `userdata.sh` 에서 `gj2026` 검색 후 교체
- `k8s/grafana-values.yaml` 에서 role annotation (`gj2026-grafana-role`) 교체



---

## 🚀 Apply — 2단계 (로컬 PowerShell → Bastion)

로컬에서는 **bastion 만** 띄우고, **bastion(Linux) 안에서 main 전체**를 apply 합니다.

```powershell
cd C:\Users\competitor\2026-terraform\1과제\06\bastion
terraform init ; terraform apply -auto-approve
terraform output -raw ssm_connect_command
```
```bash
until [ -f /opt/task1/READY ]; do sleep 5; done
bash /opt/task1/run.sh
```
```powershell
cd C:\Users\competitor\2026-terraform\1과제\06\bastion ; terraform destroy -auto-approve
```

> ⚠️ **default VPC 없음**: `bastion/main.tf` 의 default VPC 참조를 전용 VPC(10.250.0.0/16 + public subnet + IGW + route)로 교체해야 apply 됩니다(01/1과제 bastion 참고).
