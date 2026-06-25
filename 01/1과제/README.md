# 2026 전국기능경기대회 클라우드컴퓨팅 1과제 - Terraform 단일 apply

`wsc-*` 리소스를 문제지(과제지_v3) / 채점기준표(채점기준표_v2)에 맞춰 **단일 `terraform apply`** 로 구성한다.
수동 작업 없음(eksctl/스크립트 별도 실행 불필요). Windows PowerShell 기준.

> 대회 당일에는 과제가 **최대 30% 변경**될 수 있다. 아래 **[§ 값 변경 시 수정 위치](#-값-변경-시-수정-위치-대회-30-변경-대비)** 표만 보고 빠르게 수정할 수 있도록 정리해 두었다.

---

## 사전 준비
- AWS 자격증명 (ap-northeast-2, 관리자급 권한)
- `terraform` >= 1.6, `aws` CLI v2, `kubectl`, `docker` 데몬 실행 중 (PATH 등록)
- 배포파일은 `files/`(book, index.html, main.jpeg, Dockerfile, cf-function.js)에 포함됨
  - **book / index.html / main.jpeg 는 대회 배포파일 원본으로 교체되어 있음.** 새 배포파일을 받으면 `files/` 안의 동일 파일명으로 덮어쓰면 됨.

## 실행
```powershell
cd "01\1과제"
terraform init
terraform apply -auto-approve
```
- EKS/노드그룹/헬름까지 약 20~30분 소요.
- apply 중에는 EKS endpoint 가 public+private 로 열려 있어야 k8s/helm 리소스를 적용할 수 있다.

## ⚠️ 채점 직전 필수 작업 (private-only 전환)
채점기준표 5-1 은 `PublicEndpoint: False` 를 요구한다. apply 동안은 kubectl/helm 때문에 public 을 켜 두므로,
**모든 리소스 적용이 끝난 뒤** 아래 둘 중 하나로 public 을 꺼야 한다.

1. (권장, 빠름) CLI 한 줄:
   ```powershell
   aws eks update-cluster-config --region ap-northeast-2 --name wsc-eks-cluster `
     --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
   ```
2. 또는 `finalize.tf.disabled` → `finalize.tf` 로 이름을 바꾸고 `terraform apply` 재실행
   (이 파일의 `null_resource.private_only` 가 위 명령을 자동 수행).

> destroy 전에는 반대로 public 을 다시 켜야 k8s/helm 리소스를 정리할 수 있다(맨 아래 참고).

---

## 채점 항목 ↔ 구현 파일
| 채점 | 구현 파일 |
|------|-----------|
| 1 VPC/서브넷/RT/IGW/NAT/FlowLogs(KMS, 12필드) | `vpc.tf`, `kms.tf` |
| 2 S3(DSSE-KMS, SSE-C 차단, 버킷키, 비공개)+CloudFront(Function /index,/main) | `s3_cloudfront.tf`, `files/cf-function.js` |
| 3 ECR book-ecr(KMS, IMMUTABLE, scanOnPush, CVE 0) | `ecr.tf`, `files/Dockerfile` |
| 4 DynamoDB wsc-dynamo(AWS관리형KMS, PITR, 삭제방지, 온디맨드)+AWS Backup(cold30/del120) | `dynamodb.tf`, `dynamodb_backup.tf` |
| 5 EKS 1.35(private, KMS, 로깅5종)+노드그룹 app/addon+book StatefulSet | `eks.tf`, `k8s_book.tf` |
| 6 ALB wsc-alb(internet-facing, 80, IP, 404 기본)+/health,/v1/* | `alb.tf` |
| 7 Prometheus(15s, 9090)+RuleGroup book 3 alerts | `monitoring.tf` |

---

## 🔧 값 변경 시 수정 위치 (대회 30% 변경 대비)

> 형식: **바뀌는 값 → 수정할 파일 : 위치(리소스/라인 키워드)**. 여러 파일에 흩어진 값은 ⚠️ 로 표시.

### 1) 네트워크 (VPC / Subnet / Routing)
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **VPC CIDR** (예: 10.0.0.0/16) | `vpc.tf` → `resource "aws_vpc" "this"` 의 `cidr_block`. ⚠️ `kms.tf`·SG 등에서 `local.vpc_cidr` 가 아니라 직접 문자열을 쓰는 곳은 없음(서브넷 CIDR만 함께 점검) |
| **서브넷 CIDR** (pub a/b, priv a/b) | `vpc.tf` → 각 `aws_subnet.pub_a/pub_b/priv_a/priv_b` 의 `cidr_block` |
| **서브넷/VPC 이름 태그** (wsc-vpc, wsc-pub-sn-a …) | `vpc.tf` → 각 리소스 `tags = { Name = "..." }` |
| **AZ** (ap-northeast-2a/b) | `variables.tf` → `variable "azs"` 의 `default` |
| **Region** | `variables.tf` → `variable "region"` 의 `default` (전 리소스가 `var.region`/`local.region` 참조) |
| **라우팅 테이블 이름** (wsc-pub-rt, wsc-priv-rt-a/b) | `vpc.tf` → `aws_route_table.*` 의 `tags.Name` |
| **IGW/NAT 이름** (wsc-igw, wsc-nat-a/b) | `vpc.tf` → `aws_internet_gateway.this` / `aws_nat_gateway.a,b` 의 `tags.Name` |
| **NAT 개수** (HA 1개로 축소 등) | `vpc.tf` → `aws_eip.nat_b`/`aws_nat_gateway.b`/`aws_route_table.priv_b` 정리 + `priv_b` RT를 `a`로 연결 |

### 2) Flow Logs
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **로그 필드 구성** | `vpc.tf` → `aws_flow_log.this` 의 `log_format` (현재 12필드: account-id srcaddr dstaddr srcport dstport protocol start end action vpc-id subnet-id region). `$${...}` 이스케이프 유지 |
| **로그 그룹 이름** (/aws/vpc/flowlogs) | `vpc.tf` → `aws_cloudwatch_log_group.flowlogs` 의 `name` (+ `tags.Name`) |
| **보존 기간** | `vpc.tf` → `aws_cloudwatch_log_group.flowlogs` 의 `retention_in_days` |
| **암호화 KMS 키** | `vpc.tf` → `kms_key_id = aws_kms_key.main.arn` (키 자체는 `kms.tf`) |

### 3) S3 / CloudFront
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **버킷 이름 접두/비번호** (wsc-2026-bucket-<비번호>) | 비번호만: `variables.tf` → `competitor_number` default. 접두 형식: `locals.tf` → `bucket_name` |
| **암호화 방식** (aws:kms:dsse / 버킷키 / SSE-C 차단) | `s3_cloudfront.tf` → `aws_s3_bucket_server_side_encryption_configuration.static` |
| **CloudFront Function 이름** (wsc-2026-functions) | `s3_cloudfront.tf` → `aws_cloudfront_function.rewrite` 의 `name` |
| **Function 런타임** (cloudfront-js-2.0) | `s3_cloudfront.tf` → `aws_cloudfront_function.rewrite` 의 `runtime` |
| **경로 매핑 규칙** (/index→index.html, /main→main.jpeg) | `files/cf-function.js` (Function 로직) |
| **Distribution 이름/주석** (wsc-2026-cloud-front) | `s3_cloudfront.tf` → `aws_cloudfront_distribution.static` 의 `comment`/`tags.Name` |
| **정적 파일 추가/변경** | `files/` 에 파일 추가 후 `s3_cloudfront.tf` → `aws_s3_object.*` 블록 추가/수정 |

### 4) ECR
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **리포지토리 이름** (book-ecr) | `locals.tf` → `ecr_repo`. ⚠️ `locals.tf` 의 `image` 문자열에도 `book-ecr` 하드코딩되어 있으니 함께 변경 |
| **태그 불변성 / 스캔 / KMS** | `ecr.tf` → `aws_ecr_repository.book` 의 `image_tag_mutability` / `image_scanning_configuration` / `encryption_configuration` |

### 5) DynamoDB / Backup
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **테이블 이름** (wsc-dynamo) | `locals.tf` → `table_name` (테이블·IAM·앱 env 가 모두 이 값을 참조) |
| **파티션 키** (booking_id) | `dynamodb.tf` → `aws_dynamodb_table.wsc` 의 `hash_key` + `attribute` 블록 |
| **과금 모드 / PITR / 삭제방지** | `dynamodb.tf` → `aws_dynamodb_table.wsc` 의 `billing_mode`/`point_in_time_recovery`/`deletion_protection_enabled` |
| **백업 콜드전환/삭제 일수** (30/120) | `dynamodb_backup.tf` → null_resource 내 `Lifecycle = @{ MoveToColdStorageAfterDays = 30; DeleteAfterDays = 120 }` |
| **백업 vault 이름** (aws/efs/automatic-backup-vault) | `dynamodb_backup.tf` → `VAULT` 환경변수 |
| **백업 IAM Role** (AWSBackupDefaultServiceRole) | `dynamodb.tf` → `aws_iam_role.backup` 의 `name` |

### 6) EKS / 노드그룹 / 앱
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **클러스터 이름** (wsc-eks-cluster) | `locals.tf` → `cluster_name` (서브넷 태그·노드그룹·ALB 등이 참조) |
| **EKS 버전** (1.35) | `eks.tf` → `aws_eks_cluster.this` 의 `version` |
| **클러스터 로깅 종류** (5종) | `eks.tf` → `enabled_cluster_log_types` |
| **노드그룹 이름** (wsc-app/addon-nodegroup) | `eks.tf` → `aws_eks_node_group.app/addon` 의 `node_group_name` + `labels` 의 `alpha.eksctl.io/nodegroup-name` |
| **노드 인스턴스 타입** (t3.medium) | `eks.tf` → 해당 node_group 의 `instance_types` |
| **노드 인스턴스 Name 태그** (wsc-app/addon-node) | `eks.tf` → `aws_launch_template.app/addon` 의 `tag_specifications` |
| **노드 Label** (node=app / node=addon) | `eks.tf` → node_group 의 `labels` (+ app 의 `taint`). ⚠️ 바꾸면 `k8s_book.tf`(node_selector/toleration), `monitoring.tf`·`alb.tf`(nodeSelector=addon)도 함께 수정 |
| **앱 네임스페이스** (book) | `k8s_book.tf` → `kubernetes_namespace_v1.book`. ⚠️ `eks.tf` Pod Identity(`namespace="book"`), `monitoring.tf` 알람 expr 의 `namespace="book"` 함께 수정 |
| **Pod 이름 / 개수** (book-0, book-1 → replicas 2) | `k8s_book.tf` → `kubernetes_stateful_set_v1.book` 의 `metadata.name`("book") + `spec.replicas` |
| **앱 Label** (app=book) | `k8s_book.tf` → statefulset `labels`/`selector`/template `labels` (+ `kubernetes_service_v1.book` selector) |
| **앱 환경변수** (AWS_REGION, TABLE_NAME) | `k8s_book.tf` → container `env` 블록 |
| **앱 포트** (8080) | `k8s_book.tf`(container_port, probe) + `alb.tf`(target group port, SG 8080 rule) ⚠️ |

### 7) ALB
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **ALB 이름** (wsc-alb) | `alb.tf` → `aws_lb.wsc` 의 `name` |
| **Scheme / Target Type** | `alb.tf` → `aws_lb.wsc` 의 `internal=false` / `aws_lb_target_group.book` 의 `target_type="ip"` |
| **리스너 포트** (80) | `alb.tf` → `aws_lb_listener.http` 의 `port` (+ ALB SG ingress 80) |
| **기본 동작** (정의 안된 경로 404) | `alb.tf` → `aws_lb_listener.http` 의 `default_action` fixed-response 404 |
| **경로 라우팅** (/health, /v1/*) | `alb.tf` → `aws_lb_listener_rule.health` / `.book` 의 `condition.path_pattern` |

### 8) Prometheus
| 바뀌는 값 | 수정 파일 : 위치 |
|-----------|------------------|
| **scrape/eval 주기** (15s) | `monitoring.tf` → `prometheusSpec.scrapeInterval`/`evaluationInterval` |
| **Rule Group 이름** (book) | `monitoring.tf` → `additionalPrometheusRulesMap` 의 키 `"book"` + `groups[].name` |
| **Alert 이름** (BookPodNotRunning, BokPodCrashLooping, BookPodNotReady) | `monitoring.tf` → 각 rule 의 `alert` (⚠️ "BokPodCrashLooping" 오타는 과제지 그대로) |
| **알람 조건 식** | `monitoring.tf` → 각 rule 의 `expr` |
| **Prometheus 포트** (9090) | 기본값(차트 default). 변경 시 helm values 에 `prometheusSpec.... ` 포트 설정 추가 |

### 공통/전역 값 (한 곳만 고치면 전파됨 — `locals.tf`)
`cluster_name`, `ecr_repo`, `table_name`, `bucket_name`, `image`, `registry` 는 모두 `locals.tf` 에 모여 있다.
이름류가 바뀌면 **먼저 `locals.tf` 부터** 확인. (단 `image`·`bucket_name` 처럼 다른 값과 조합된 문자열은 조합 요소도 점검)

---

## destroy 시 주의
private-only 로 닫았다면 destroy 전에 public 을 잠시 켜야 k8s/helm 리소스를 정리할 수 있다.
```powershell
aws eks update-cluster-config --region ap-northeast-2 --name wsc-eks-cluster `
  --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
# 활성화(약 수 분) 후
terraform destroy
```

## 검증 상태
- `terraform fmt` / `terraform validate` 통과 (구성 유효).
- 실제 `apply`(EKS 프로비저닝/도커 빌드/헬름)는 환경에서 직접 1회 수행하여 최종 확인 필요.
- DynamoDB AWS Backup 은 `dynamodb_backup.tf`(AWS CLI null_resource)로 생성 — EFS 자동백업 vault 시드 후 plan/selection 등록.
