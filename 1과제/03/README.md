> # 🚀 배포 방법 (이 안내가 최신/정답 — 아래 본문 구버전 무시)
>
> 로컬에서 **bastion 스테이지만** apply(전용 VPC+bastion 생성 + 이 소스를 번들로 업로드),
> 그 다음 **bastion 안에서 `run.sh`** 로 root(EKS/ALB/…) → k8s/helm → CloudFront 순서로 apply.
>
> ```powershell
> # Phase 1 (로컬): 새 VPC + bastion + 소스 번들
> cd C:\Users\competitor\2026-terraform\1과제\03\bastion
> terraform init; terraform apply -auto-approve
> terraform output -raw ssm_connect_command   # 또는 SSH
> ```
> ```bash
> # Phase 2 (bastion): 3단계 자동 (root deploy_cdn=false → k8s → root deploy_cdn=true)
> until [ -f /opt/task1/READY ]; do sleep 5; done
> BIBUNHO=<비번호> GRADER=arn:aws:iam::<acct>:user/<채점자> bash /opt/task1/run.sh
> ```
>
> ## ⚑ KMS 배포 원칙
>
> 채점 스크립트는 서비스별 실제 키 ARN과 아래 고정 별칭을 비교하므로, 잠긴 과거 키를 재사용하지 않습니다.
> 이 구성은 배포할 때마다 Terraform state가 관리하는 CMK 5개와 별칭을 생성합니다.
>
> - `wsc2026-db-kms`
> - `wsc2026-ecr-kms`
> - `wsc2026-eks-kms`
> - `wsc2026-bucket-kms`
> - `wsc2026-function-kms`
>
> `reuse_kms`와 `kms_key_arns` 변수는 이전 실행 명령 호환용으로만 남아 있으며 값과 관계없이 신규 키를 사용합니다.
> `kms_admin_arn`은 일회성 STS 세션 ARN이 아닌 지속되는 IAM role ARN이어야 합니다.
>
> ## ⚠️ 편집 시 CRLF 금지
> `.tf`/`.sh` 를 Windows 에서 편집하면 `\r\n` 이 들어가 `ecr.tf` 의 bash local-exec 가
> `set: invalid option`, `path "./files\r" not found` 로 깨진다. **반드시 LF** 로 저장할 것.



# WSC2026 제1과제 Terraform (인천기능경기대회 v2)

문제지(`과제지_v2.pdf`) + 채점기준표(`채점기준표_v2.pdf`) 기준으로 작성.
모든 리소스는 **ap-northeast-2(서울)**. CloudFront/WAF 만 us-east-1.

---

## 0. 디렉터리

| 파일 | 내용 |
|---|---|
| `versions.tf` / `providers.tf` | provider 버전, aws(서울/us-east-1), kubernetes/helm |
| `variables.tf` | **대회 중 바뀌는 값의 변수 모음** (region, az, 비번호, 버전, 도메인, grafana pw, kms admin) |
| `locals.tf` | **이름/CIDR/서브넷 등 고정값 모음** (대부분의 이름 변경은 여기) |
| `vpc.tf` | VPC, 4서브넷(hub/app), IGW, NAT×2, RTB×3 |
| `kms.tf` | CMK 5종 (db/ecr/eks/bucket/function) — root·kms:* 금지 최소권한 |
| `dynamodb.tf` | 테이블 + GSI + PITR + 삭제방지 + 리소스정책 |
| `ecr.tf` | ECR(MUTABLE_WITH_EXCLUSION v1*) + 이미지 빌드/푸시 |
| `eks.tf` | 클러스터(Fully Private) + addon(coredns 도메인 등) |
| `eks_nodegroups.tf` | addon / workload 노드그룹 |
| `iam_app.tf` | book-pod-role(PutItem), book-function-role(Query) |
| `lambda.tf` | GET Lambda + Function URL + CMK env |
| `s3.tf` | 정적 버킷(SSE-KMS) + OAC 정책 |
| `alb.tf` | ALB SG(CloudFront only) + 생성된 ALB 조회 |
| `k8s_app.tf` | ns/configmap/deploy/svc/pdb/sa/ingress + LB Controller |
| `waf.tf` | SQLi/XSS/RateLimit |
| `cloudfront.tf` | CDN 3-origin(S3/ALB/Lambda) + /booking→/v1/book |
| `logging.tf` | Fluent Bit → CloudWatch |
| `monitoring.tf` + `k8s/kps-values.yaml.tftpl` | Prometheus/Alertmanager/Grafana |
| `bastion.tf` | (선택) Private EKS 작업용 점프호스트 |
| `files/` | book 바이너리, index.html, main.jpeg, Dockerfile, lambda, 정책 |

---

## 1. 적용 순서

> EKS 가 **Fully Private** 라서, 채점 시점엔 `endpoint_public_access=false` 여야 한다(채점 4-1).
> 하지만 로컬(Windows)에서 k8s/helm 을 apply 하려면 apply 동안엔 endpoint 가 열려 있어야 한다.

**방법 A — 로컬에서 2단계 apply (권장 X, 간단)**
```bash
terraform init
# 1) 퍼블릭 켜고 전체 생성 (기본값 eks_public_access=true)
terraform apply -auto-approve -var="bi_number=<비번호>" -var="bucket_rand=<영문4>"
# 2) 채점 전 퍼블릭 끄기
terraform apply -auto-approve -var="eks_public_access=false" -var="bi_number=<비번호>" -var="bucket_rand=<영문4>"
```

**방법 B — Bastion 에서 apply (권장)**
`bastion.tf` 로 점프호스트 생성 → SSH 접속 → 그 안에서 `terraform apply`.
VPC 내부라 endpoint 가 private(false) 여도 k8s/helm 적용 가능 → 1번에 끝.

> docker 빌드/푸시(`ecr.tf`)는 docker 데몬 + 인터넷이 필요하다. Bastion 에서 할 경우 docker 설치 필요.

적용 후 확인:
```bash
terraform output cloudfront_domain   # 채점 진입점
```

---

## 2. ⭐ 변경 매핑표 (값이 바뀌면 어디를 고치나)

대회에서 과제가 최대 30% 수정될 수 있다. 아래 표대로 **해당 위치만** 고치면 된다.
대부분은 `locals.tf` / `variables.tf` 한 곳에서 끝나도록 묶어두었다.

### 2-1. 네트워크 (Reference01)

| 바뀌는 값 | 고칠 파일 | 위치 |
|---|---|---|
| VPC CIDR (192.168.0.0/16) | `locals.tf` | `vpc_cidr` |
| VPC 이름 (wsc2026-skills-vpc) | `vpc.tf` | `aws_vpc.this` 의 `tags.Name` |
| 서브넷 CIDR/이름/AZ | `locals.tf` | `subnets` 맵의 각 항목 (`cidr`,`name`,`az`,`public`) |
| 서브넷 개수 변경 | `vpc.tf` | `aws_subnet.*` + RTB association 추가/삭제 |
| AZ (a/b → 다른 조합) | `variables.tf` | `azs` 기본값 |
| IGW 이름 | `vpc.tf` | `aws_internet_gateway.this.tags.Name` |
| NAT 이름 | `vpc.tf` | `aws_nat_gateway.a/b.tags.Name` |
| RTB 이름 (hub-rtb / app-rtb-a/b) | `vpc.tf` | `aws_route_table.hub/app_a/app_b.tags.Name` |
| hub(public)↔app(private) 매핑 | `vpc.tf` | RTB association + NAT subnet_id |

### 2-2. 이름/리전 공통

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| 리전 | `variables.tf` | `region` |
| EKS 클러스터 이름 | `locals.tf` | `cluster_name` |
| EKS 버전 (1.35) | `variables.tf` | `cluster_version` |
| 내부 도메인 (wsc2026.skills.local) | `variables.tf` | `cluster_dns_domain` (coredns 는 `eks.tf` 가 자동 반영) |
| ECR 이름 | `locals.tf` | `ecr_repo` |
| 이미지 태그 (v1.0.0) | `locals.tf` | `image_tag` |
| DynamoDB 테이블 이름 | `locals.tf` | `table_name` |
| 테이블 PK (client_id) | `dynamodb.tf` | `hash_key` + `attribute` |
| GSI 키 (booking_id) | `dynamodb.tf` | `global_secondary_index` (+ `iam_app.tf` 정책 ARN, `files/lambda_function.py` 의 `INDEX_NAME` 상수) |
| S3 버킷 임의4자리/비번호 | `variables.tf` | `bucket_rand`, `bi_number` |

### 2-3. CMK 이름 (alias)

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| db/ecr/eks/bucket/function CMK 이름 | `locals.tf` | `kms_db`,`kms_ecr`,`kms_eks`,`kms_bucket`,`kms_function` |
| CMK 관리 주체(assumed-role 로 apply 시) | `variables.tf` | `kms_admin_arn` 에 **role ARN** 지정 |

> ⚠️ CMK 정책엔 `root` 와 `kms:*` 가 들어가면 채점 FAIL(check_kms). 관리 권한은
> `kms.tf` 의 `kms_admin_actions`(구체 액션 나열)로만 부여한다. 새 CMK 추가 시 동일 패턴 사용.

### 2-4. Deployment / 앱 (과제 8)

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| Deployment/Service/Ingress/PDB/SA 이름 | `locals.tf` | `deploy_name` 등 |
| 네임스페이스 (wsc2026) | `locals.tf` | `app_namespace` |
| ConfigMap 이름 (book-config) | `k8s_app.tf` | `kubernetes_config_map_v1.book` (채점이 `book-config` 로 조회) |
| replica 수 | `k8s_app.tf` | `kubernetes_deployment_v1.book` `replicas` |
| CPU/Mem (250m/512Mi) | `k8s/main.tf` | `resources.requests/limits` |
| Probe 경로/포트 (/health:8080) | `k8s_app.tf` | `*_probe.http_get` |
| 노드 라벨 (wsc2026/node) | `eks_nodegroups.tf` `labels` + `k8s_app.tf` `node_selector` |
| Pod Identity 역할 권한 | `iam_app.tf` | `aws_iam_policy.book_pod` (※ Action 에 `*` 절대 금지) |

### 2-5. Lambda (과제 10)

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| 함수 이름/런타임(py3.12) | `lambda.tf` | `aws_lambda_function.book_get` |
| 환경변수 | `lambda.tf` | `environment.variables` |
| 응답 컬럼 순서/날짜포맷 | `files/lambda_function.py` | `out` dict / `_fmt_created_at` |
| IAM role/policy 이름 | `locals.tf` | `func_role_name`,`func_policy` (※ Action 에 `*` 금지) |

### 2-6. CloudFront / WAF / ALB

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| POST 경로 (/booking) | `cloudfront.tf` | `ordered_cache_behavior` path + `aws_cloudfront_function.rewrite_booking` |
| GET 경로 (/v1/book) | `cloudfront.tf` | `ordered_cache_behavior` + `files/lambda_function.py` |
| 캐시 정책(S3 on / ALB·Lambda off) | `cloudfront.tf` | 각 behavior 의 `cache_policy_id` |
| WAF Rate 임계 (200/1분) | `waf.tf` | `rate_based_statement.limit` / `evaluation_window_sec` |
| WAF 룰(SQLi/XSS) | `waf.tf` | `rule` 블록 |
| ALB 이름/스킴/SG | `locals.tf`(`alb_name`,`alb_sg_name`) + `k8s_app.tf` ingress annotations |
| CDN/WAF 이름 | `locals.tf` | `cdn_name`,`waf_name` |

### 2-7. Observability (과제 11)

| 바뀌는 값 | 파일 | 위치 |
|---|---|---|
| Grafana admin pw | `variables.tf` | `grafana_admin_password` |
| 보존기간(7일) | `k8s/kps-values.yaml.tftpl` | `prometheus.prometheusSpec.retention` |
| Alert 규칙(6종) | `k8s/kps-values.yaml.tftpl` | `additionalPrometheusRulesMap` |
| Alertmanager 라우팅/리시버 | `k8s/kps-values.yaml.tftpl` | `alertmanager.config` |
| Datasource(prometheus/alertmanager/cloudwatch) | `k8s/kps-values.yaml.tftpl` | `grafana.additionalDataSources` |
| 대시보드 이름/패널 | `locals.tf`(`dashboard_name`) + `k8s/wsc-eks-dashboard.json` |
| 대시보드 상단 필터(nodegroup/namespace) | `k8s/wsc-eks-dashboard.json` | `templating.list` |
| Fluent Bit 파서/필터/메트릭 | `k8s/fb/fluent-bit.conf`, `fb/parser_extra.conf`, `fb/reformat.lua` |
| FB 메트릭 수집(ServiceMonitor) | `k8s/fb/fb-metrics-sm.yaml` | `metricRelabelings` |
| 로그그룹 이름 | `logging.tf` | `aws_cloudwatch_log_group.app.name` |

---

## 3. 적용 후 직접 손봐야 할 가능성이 있는 부분 (검증 필수)

테라폼 plan/apply 는 통과하지만, 라이브 환경에서 다음은 **채점 전 반드시 확인**:

1. **Grafana 대시보드** (`k8s/wsc-eks-dashboard.json`) — 상단 `Node Group`/`Namespace` 변수로
   필터되며, CPU 80%↑ 빨강 / 60~80% 노랑 / 60%↓ 초록, Pod restart≥1 빨강(경고)로 맞춰두었다.
   패널 17종(Node CPU/Memory, Available Nodes, Pod CPU/Memory, Pending Pods, Pod Restarts,
   App Pod CPU/Memory, App Running/Restarts/Pending, Request Count, Response Time,
   Status Code, Application Logs, Active Alerts)이 채점 목록과 1:1 대응한다.
   ※ `namespace` 변수 기본값은 `wsc2026`, `nodegroup` 기본값은 `All`.
2. **Fluent Bit 파싱** — 지급 book 앱은 logfmt
   (`access method=.. path=.. status=.. duration=..`)이라 `fb/parser_extra.conf` 의
   `book_access` 정규식으로 파싱하고 `fb/reformat.lua` 의 `reformat` 이
   Reference02 형식(`INFO {json}`)으로 재구성한다. 로그 형식이 바뀌면 이 두 파일을 수정.
3. **Alert 규칙 expr** — 지급 book 앱은 `/metrics` 를 노출하지 않으므로
   `http_requests_total`(counter) 과 `http_request_duration_seconds`(gauge)를
   `fb/fluent-bit.conf` 의 `log_to_metrics` 로 액세스 로그에서 생성하고,
   `fb/fb-metrics-sm.yaml` 의 ServiceMonitor(rename relabel)로 Prometheus 가 수집한다.
   6종(PodHighCPU / PodHighMemory / PodNotReady / PodCrashLooping / HighErrorRate /
   HighLatency) 모두 `for: 1m` 이라 채점 스크립트의 부하 생성 + `sleep 180` 안에서 발화한다.
   `HighLatency` 임계치는 앱에 지연 엔드포인트가 없어 API SLO(20ms)로 잡았다.
4. **EKS 채점자 접근** — 채점은 Cloudshell(`wsc2026-skills-app-sub-a`+mark-sg)에서 kubectl.
   채점자 자격증명이 클러스터 access entry 에 없으면 `eks.tf` 에 access entry 추가 필요.
5. **CloudFront ↔ ALB** — ALB SG 가 CloudFront origin-facing prefix list 만 허용(직접 접근 BLOCKED).
   `/booking`→`/v1/book` rewrite 동작 확인.
6. **이미지 취약점 0** — `files/Dockerfile` 은 scratch 기반. 스캔 COMPLETE/취약점 0 확인.



---

## 🚀 Apply — 2단계 (로컬 PowerShell → Bastion)

로컬에서는 **bastion 만** 띄우고, **bastion(Linux) 안에서 main 전체**를 apply 합니다.

```powershell
cd C:\Users\competitor\2026-terraform\1과제\03\bastion
terraform init ; terraform apply -auto-approve
terraform output -raw ssm_connect_command
```
```bash
until [ -f /opt/task1/READY ]; do sleep 5; done
bash /opt/task1/run.sh        # EKS + helm, 마지막 finalize 에서 EKS private-only 전환(채점 4-1)
```
```powershell
cd C:\Users\competitor\2026-terraform\1과제\03\bastion ; terraform destroy -auto-approve
```

> ⚠️ 구 `bastion.tf` 는 `bastion.tf.OLD-in-main` 으로 비활성화됨(외부 bastion/ 스테이지로 대체).
> ⚠️ **default VPC 없음**: `bastion/main.tf` 의 default VPC 참조를 전용 VPC 로 교체해야 apply 됩니다(01/1과제 bastion 참고).


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\1과제\03\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.
