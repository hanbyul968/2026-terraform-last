# 1과제 실행 가이드

---

## Step 1 — 로컬에서 Terraform 실행

```bash
cd C:\Users\competitor\2026-terraform\06\1과제
terraform init
terraform apply --auto-approve
# 프롬프트에서 비번호 입력 (예: 103)
```

> 생성되는 주요 리소스: VPC / KMS / S3 / DynamoDB / ECR / Lambda / ALB / CloudFront / WAF / IAM / Grafana ALB / CloudShell SG / manifest S3 버킷

---

## Step 2 — CloudShell VPC Environment 생성 (콘솔 수동)

AWS 콘솔 → CloudShell → VPC Environment 생성

| 항목 | 값 |
|---|---|
| Name | `unicorn-mark` |
| VPC | `unicorn-vpc` |
| Subnet | Private Subnet 아무거나 |
| Security Group | `unicorn-mark-sg` |

---

## Step 3 — CloudShell 접속 후 실행

```bash
# 1. 환경변수 설정
export number=<비번호>

# 2. AWS 자격증명 설정 (default region: ap-northeast-2)
aws configure

# 3. S3에서 파일 다운로드 + apply.sh 실행 (한 줄)
aws s3 cp s3://$(aws s3 ls | grep unicorn-manifest | awk '{print $3}')/ ./ --recursive && source apply.sh
```

> CloudShell 세션 만료로 끊기면 다시 접속 후 동일 명령어 재실행

**apply.sh 자동 처리 목록:**

| 순서 | 내용 |
|---|---|
| 1 | book 이미지 빌드 & ECR push (v1.0.0, latest) |
| 2 | ECR IMMUTABLE_WITH_EXCLUSION 설정 (latest 제외) |
| 3 | eksctl로 EKS 클러스터 생성 (`unicorn-eks-cluster`) |
| 4 | EKS 클러스터 SG에 CloudShell SG / VPC CIDR 인바운드 허용 |
| 5 | kubectl apply (namespace → SA → deployment → service → fluentd → fluent-bit) |
| 6 | EC2 노드에 Name 태그 부여 |
| 7 | Pod Identity Association 생성 |
| 8 | Pod 재기동 + ALB Target Group에 Pod IP 등록 |
| 9 | Helm으로 Prometheus + Grafana 설치 (monitoring namespace) |
| 10 | Grafana ALB Target Group에 addon 노드 등록 |
| 11 | 노드 Role에 CloudWatchLogsFullAccess 부여 / 현재 IAM 유저에 Audit Role AssumeRole 권한 부여 |

---

## Step 4 — Grafana 대시보드 생성 (수동)

### 접속

브라우저 → `unicorn-grafana-alb` DNS 주소

| Userid | Password |
|---|---|
| `skills<비번호>` | `HelloKrSkills!<비번호>@` |

### Dashboard 생성

Dashboard Name: **`unicorn-grafana-dashboard`**

| # | Panel Name | Panel Type | PromQL |
|---|:---|:---|:---|
| 1 | EKS Node CPU Usage (%) | Time series | `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| 2 | EKS Node Memory Usage (%) | Time series | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| 3 | unicorn Namespace Pod Status | Stat | `sum by (phase) ( kube_pod_status_phase{ namespace="unicorn" } )` |
| 4 | Book App Ready Pods | Stat | `count( kube_pod_status_ready{ namespace="unicorn", condition="true", pod=~"unicorn-book-app.*" } == 1 )` |
| 5 | Book App HTTP Request Duration | Time series | `quantile(0.<퍼센타일>, rate(container_cpu_usage_seconds_total{namespace="unicorn", container="book"}[5m])) * 1000` |

> Panel 3은 Stat + graph 포함. 패널 순서, 이름 대소문자는 채점 시 무시.

---

## 과제 변경 시 수정 위치 가이드

> 대회 당일 과제지가 최대 30% 변경될 수 있으므로 아래 표를 참고해 해당 파일만 수정하세요.

### 빠른 체크리스트 (과제지 받은 직후 확인)

- [ ] VPC CIDR → `main.tf` `module "VPC"` `vpc_cidr`
- [ ] 서브넷 CIDR/이름/AZ 수 → `main.tf` `module "VPC"` 리스트 전체
- [ ] KMS alias / 교체주기 → `main.tf` `module "KMS"`
- [ ] S3 버킷 이름 규칙 → `main.tf` `module "S3"` `bucket_name`
- [ ] DynamoDB 테이블명 / PK / GSI → `main.tf` `module "DynamoDB"` + `manifest/deployment.yaml` TABLE_NAME
- [ ] ECR 레포 이름 / 이미지 태그 → `main.tf` + `manifest/apply.sh` + `manifest/deployment.yaml`
- [ ] EKS 클러스터명 / 버전 / 노드 스펙 → `manifest/cluster.yaml`
- [ ] Lambda 함수명 / 로그 그룹 → `main.tf` `module "Lambda"`
- [ ] ALB / TG / Grafana ALB 이름 → `main.tf`
- [ ] WAF rate limit (횟수/시간) → `modules/CloudFront/waf.tf`
- [ ] Audit Role 이름 / External ID 형식 → `main.tf` `module "IAM"`
- [ ] App 포트 / Health 경로 → `manifest/deployment.yaml`, `manifest/service.yaml`
- [ ] Grafana 계정 형식 → `manifest/apply.sh`

---

### 1. VPC / 네트워크

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| VPC CIDR (현재: `10.97.0.0/16`) | `main.tf` | `module "VPC"` → `vpc_cidr` |
| VPC CIDR 변경 시 추가 | `manifest/apply.sh` | 62번째 줄 `--cidr 10.97.0.0/16` |
| Public 서브넷 CIDR (현재: 0, 1, 2번째 /24) | `main.tf` | `module "VPC"` → `public_subnets_cidr` |
| Private 서브넷 CIDR (현재: 10, 11, 12번째 /24) | `main.tf` | `module "VPC"` → `private_subnets_cidr` |
| VPC / 서브넷 / IGW / NAT / RT 이름 | `main.tf` | `module "VPC"` → 각 `_name` / `_names` 변수 |
| AZ 수 변경 (3→2 등) | `main.tf` | `module "VPC"` 안의 리스트 변수 개수를 모두 맞춤 |

---

### 2. KMS

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 키 alias (app / data / platform) | `main.tf` | `module "KMS"` → `app_key_alias`, `data_key_alias`, `platform_key_alias` |
| platform alias 변경 시 추가 | `modules/KMS/replica.tf` | `aws_kms_alias.platform_replica` → `name` |
| platform alias 변경 시 추가 | `manifest/apply.sh` | 31번째 줄 `alias/unicorn-kms-platform` |
| 교체 주기 (현재: `90`일) | `main.tf` | `module "KMS"` → `rotation_period` |

---

### 3. S3

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 버킷 이름 (현재: `unicorn-web-<ACCOUNT_ID>`) | `main.tf` | `module "S3"` → `bucket_name` |
| 암호화 키 변경 | `main.tf` | `module "S3"` → `kms_key_arn` |

---

### 4. DynamoDB

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 테이블 이름 (현재: `unicorn-concert-db`) | `main.tf` | `module "DynamoDB"` → `table_name` |
| 테이블 이름 변경 시 추가 | `manifest/deployment.yaml` | `env` → `TABLE_NAME` |
| Partition Key (현재: `booking_id`) | `main.tf` | `module "DynamoDB"` → `hash_key` |
| GSI 이름 (현재: `client-id-created-at-index`) | `main.tf` | `module "DynamoDB"` → `gsi_name` |
| GSI PK / SK / Projection | `main.tf` | `module "DynamoDB"` → `gsi_hash_key`, `gsi_range_key`, `gsi_projection` |

---

### 5. ECR

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 레포 이름 (현재: `unicorn-concert-app`) | `main.tf` | `module "ECR"` → `repository_name` |
| 레포 이름 변경 시 추가 | `manifest/apply.sh` | 44번째 줄 `ECR_URL`, 51번째 줄 `--repository-name` |
| 이미지 태그 (현재: `v1.0.0`, `latest`) | `manifest/apply.sh` | 47번째 줄 `docker build/push` 태그 |
| 이미지 태그 변경 시 추가 | `manifest/deployment.yaml` | `image:` 줄 태그 부분 |

---

### 6. EKS

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 클러스터 이름 (현재: `unicorn-eks-cluster`) | `manifest/cluster.yaml` | `metadata.name` |
| 클러스터 이름 변경 시 추가 | `main.tf` | `aws_iam_role.book_app` → `aws:SourceArn` / `aws_eks_pod_identity_association` → `cluster_name` / `module "IAM"` → `eks_cluster_arn` |
| 클러스터 이름 변경 시 추가 | `manifest/apply.sh` | 59, 63, 64, 66, 67, 86, 90, 93, 94번째 줄 |
| EKS 버전 (현재: `1.35`) | `manifest/cluster.yaml` | `metadata.version` |
| 노드 인스턴스 타입 (현재: `t3.medium`) | `manifest/cluster.yaml` | `managedNodeGroups[].instanceType` |
| 노드 수 (app-ng: 2, addon-ng: 1) | `manifest/cluster.yaml` | `desiredCapacity`, `minSize`, `maxSize` |
| 노드 레이블 (`unicorn: app/addon`) | `manifest/cluster.yaml` | `managedNodeGroups[].labels` |
| 노드 레이블 변경 시 추가 | `manifest/deployment.yaml` | `nodeSelector` |
| 노드 레이블 변경 시 추가 | `manifest/fluentd.yaml` | Deployment `nodeSelector` |
| 노드 레이블 변경 시 추가 | `manifest/apply.sh` | 78~83번째 줄 `-l unicorn=app/addon` / 118번째 줄 |
| App Namespace (현재: `unicorn`) | `manifest/namespace.yaml` | `metadata.name` |
| Namespace 변경 시 추가 | `manifest/deployment.yaml`, `service.yaml`, `serviceaccount.yaml`, `fluent-bit.yaml`, `fluentd.yaml` | 각 파일 `namespace:` 필드 |
| Namespace 변경 시 추가 | `manifest/apply.sh` | 86번째 줄 `--namespace`, 96번째 줄 `-n unicorn` |
| Namespace 변경 시 추가 | `main.tf` | `aws_eks_pod_identity_association` → `namespace` |

---

### 7. Lambda

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| 함수 이름 (현재: `unicorn-get-booking-func`) | `main.tf` | `module "Lambda"` → `function_name` |
| 로그 그룹 (현재: `/unicorn/lambda/get-booking`) | `main.tf` | `module "Lambda"` → `log_group_name` |
| 암호화 키 변경 | `main.tf` | `module "Lambda"` → `kms_key_arn` |
| Lambda 코드 수정 | `modules/Lambda/index.py` | 직접 수정 (zip은 terraform이 자동 재생성) |

---

### 8. ALB / CloudFront / WAF

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| ALB 이름 (현재: `unicorn-alb`) | `main.tf` | `module "ALB"` → `alb_name` |
| ALB TG 이름 (현재: `unicorn-tg`) | `main.tf` | `module "ALB"` → `tg_name` |
| ALB TG 이름 변경 시 추가 | `manifest/apply.sh` | 95번째 줄 `--names unicorn-tg` |
| Grafana ALB 이름 (현재: `unicorn-grafana-alb`) | `main.tf` | `aws_lb.grafana` → `name` |
| Grafana TG 이름 (현재: `unicorn-grafana-tg`) | `main.tf` | `aws_lb_target_group.grafana` → `name` |
| Grafana TG 이름 변경 시 추가 | `manifest/apply.sh` | 117번째 줄 `--names unicorn-grafana-tg` |
| Grafana NodePort (현재: `30300`) | `main.tf` | `aws_lb_target_group.grafana` → `port`, `health_check.port` |
| Grafana NodePort 변경 시 추가 | `manifest/apply.sh` | 109번째 줄 `nodePort=30300`, 119번째 줄 `Port=30300` |
| CloudFront 이름 (현재: `unicorn-svc-cf`) | `main.tf` | `module "CloudFront"` → `distribution_comment` |
| WAF 이름 (현재: `unicorn-waf`) | `main.tf` | `module "CloudFront"` → `waf_name` |
| WAF Rate Limit (현재: `50`회 / `60`초) | `modules/CloudFront/waf.tf` | `rate_based_statement` → `limit`, `evaluation_window_sec` |
| S3 정적 캐싱 경로 (현재: `/static/*`) | `modules/CloudFront/main.tf` | `ordered_cache_behavior` → `path_pattern` |

---

### 9. IAM Audit Role

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| Role 이름 (현재: `unicorn-audit-role`) | `main.tf` | `module "IAM"` → `role_name` |
| External ID (현재: `unicorn-audit-2026<비번호>`) | `main.tf` | `module "IAM"` → `external_id` 문자열 |

---

### 10. Application

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| App 포트 (현재: `8080`) | `manifest/deployment.yaml` | `containerPort`, Probe `port` |
| App 포트 변경 시 추가 | `manifest/service.yaml` | `targetPort` |
| App 포트 변경 시 추가 | `manifest/apply.sh` | 97번째 줄 `Port=8080` |
| Health 경로 (현재: `/health`) | `manifest/deployment.yaml` | Liveness/Readiness `path` |
| Health 경로 변경 시 추가 | `modules/ALB/main.tf` | `aws_lb_target_group.app` → `health_check.path` |
| API 경로 (현재: `/v1/book`) | `modules/ALB/main.tf` | `aws_lb_listener_rule.lambda_get` → `path_pattern` |
| ServiceAccount 이름 (현재: `unicorn-book-app-sa`) | `manifest/serviceaccount.yaml` | `metadata.name` |
| SA 이름 변경 시 추가 | `manifest/deployment.yaml`, `manifest/fluent-bit.yaml`, `manifest/fluentd.yaml` | `serviceAccountName` |
| SA 이름 변경 시 추가 | `manifest/apply.sh` | 87번째 줄 `--service-account` |
| SA 이름 변경 시 추가 | `main.tf` | `aws_eks_pod_identity_association` → `service_account` |
| Deployment 이름 (현재: `unicorn-book-app-deploy`) | `manifest/deployment.yaml` | `metadata.name` |
| Deployment 이름 변경 시 추가 | `manifest/fluent-bit.yaml` | `Path` 패턴 `unicorn-book-app-deploy-*` |
| Deployment 이름 변경 시 추가 | `manifest/apply.sh` | 93, 94번째 줄 |
| Grafana 계정 형식 | `manifest/apply.sh` | 106~107번째 줄 `adminUser`, `adminPassword` |

---

### 11. Observability

**로그 파이프라인: Fluent Bit (DaemonSet / 모든 노드) → Fluentd (Deployment / addon 노드) → CloudWatch Logs**

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| Fluentd 연결 주소 / 포트 | `manifest/fluent-bit.yaml` | `[OUTPUT]` → `Host`, `Port` |
| Health 로그 제외 필터 | `manifest/fluent-bit.yaml` | `[FILTER] grep Exclude log /health` |
| CW 로그 그룹 (현재: `/unicorn/eks/book-app`) | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `log_group_name` |
| 로그 그룹 변경 시 추가 | `main.tf` | `aws_cloudwatch_log_group.book_app` → `name` |
| Fluentd flush 간격 (현재: `10s`) | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `<buffer>` → `flush_interval` |
| Fluentd region | `manifest/fluentd.yaml` | ConfigMap `fluent.conf` → `region` + Deployment env `AWS_REGION` |
| Fluentd nodeSelector (현재: `addon`) | `manifest/fluentd.yaml` | Deployment → `nodeSelector.unicorn` |
| monitoring namespace (현재: `monitoring`) | `manifest/monitoring-ns.yaml` | `metadata.name` |

---

### 12. 공통

| 변경 항목 | 수정 파일 | 수정 위치 |
|:---|:---|:---|
| AWS 리전 (현재: `ap-northeast-2`) | `main.tf` | `provider "aws"` → `region` |
| 리전 변경 시 추가 | `manifest/cluster.yaml` | `metadata.region` |
| 리전 변경 시 추가 | `manifest/deployment.yaml` | env `AWS_REGION` |
| 리전 변경 시 추가 | `manifest/apply.sh` | 8번째 줄 `REGION=`, 47번째 줄 ECR URL 리전 |
| 비번호 | `terraform apply` | 프롬프트 입력 또는 `-var="number=<비번호>"` |
