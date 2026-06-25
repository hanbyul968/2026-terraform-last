# 제1과제 — Web Service Provisioning (과제지_vf 기준)

2026 전국기능경기대회 클라우드컴퓨팅 **제1과제(`과제지_vf`)** Terraform 구성.
EKS 기반 콘서트 예약 REST API + 정적 웹(S3/CloudFront) + 모니터링.

> ✅ `terraform init` / `terraform validate` 통과 확인됨.
> 자격증명이 있는 환경(CloudShell 또는 로컬)에서 아래 **§2 배포 절차**대로 apply 할 것.
> 채점은 전부 **CloudShell** 에서 진행되며, 채점 진입점은 **CloudFront 도메인**이다.

---

## 1. 구성 요약 (어떤 .tf 가 무엇을 만드나)

| 파일 | 과제 항목 | 핵심 리소스 |
|------|-----------|-------------|
| `vpc.tf` | 3. Network | VPC `172.16.0.0/16`, pub/priv 서브넷 c·d, IGW(book-igw), NAT(book-ngw-c/d), 라우팅 |
| `kms.tf` | 전 항목 | CMK 3종: `wskorea26-s3-key` / `-dynamodb-key` / `-eks-key` |
| `s3.tf` | 4. S3 | 버킷 `wskorea26-concert-bucket-<비번호>`, 객체 `web/main/*`, OAC 전용 |
| `ecr.tf` | 6. ECR | `wskorea26-book-repo` (scanOnPush, KMS), book 이미지 빌드·푸시(`stable`) |
| `dynamodb.tf` | 7. DynamoDB | `wskorea26-data-table` (client_id, 삭제방지, KMS, GSI) |
| `eks.tf` | 8. EKS | `wskorea26-cluster` v1.35, 로그5종, secret KMS, addon, `wskorea26-vpc-environment-sg` |
| `eks_nodegroups.tf` | 8. EKS | `wskorea26-addon-ng` / `wskorea26-app-ng` (t3.medium, node-type 라벨) |
| `lambda.tf` + `files/lambda_function.py` | 9. Lambda | `wskorea26-book-lambda` (python3.14) |
| `alb.tf` | 10. ALB | `wskorea26-book-alb` (internet-facing, HTTP 80, 헤더검증 403), LB Controller, TGB |
| `cloudfront.tf` | 11. CloudFront | `wskorea26-concert-cf`, S3/ALB origin, 헤더, /book 경로 재작성 함수 |
| `k8s_app.tf` | 5. Application | ns `wskorea26`, book Deployment/Service/ConfigMap, Pod Identity, StorageClass |
| `monitoring.tf` + `k8s/*` | 12. Monitoring | Prometheus/Grafana(monitoring ns), `wskorea26-grafana-alb`, 대시보드 |
| `logging.tf` | 12. Monitoring | Fluent Bit -> CloudWatch `/wskorea26/pod/log` |
| `variables.tf` / `locals.tf` | — | **대회 중 바뀌는 값은 거의 다 여기** |

---

## 2. 배포 절차

```bash
# 0) 비번호 설정 (필수!) — variables.tf 의 bi_number 기본값을 본인 비번호로
#    또는 apply 시 -var 로 주입
terraform init
terraform apply -var="bi_number=103"      # 예: 비번호 103
```

전제 도구: terraform, aws CLI(자격증명), docker(데몬 실행), kubectl, helm.
docker 가 필요한 이유 = `ecr.tf` 가 book 이미지를 빌드해서 ECR 에 push 하기 때문.
(CloudShell 에는 docker 가 없으므로 이미지 빌드/푸시는 docker 가 있는 환경에서 수행)

apply 순서 의존성은 `depends_on` 으로 처리되어 있으나, EKS/헬름 타이밍 때문에
간헐 실패 시 `terraform apply` 를 한 번 더 실행하면 수렴한다.

---

## 3. ⭐ 대회 중 값 변경 매핑표 (최대 30% 변형 대비)

> "이 값이 바뀌면 → 이 파일의 여기를 고친다". **모든 이름/태그/변수는 대소문자 구분.**

### 3-1. 네트워크 (Reference01)

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|-----------|-----------|-----------|
| **VPC CIDR** (172.16.0.0/16) | `locals.tf` | `vpc_cidr` |
| **서브넷 CIDR** (각 /24) | `locals.tf` | `subnets.{pub_c,pub_d,priv_c,priv_d}.cidr` |
| **서브넷 이름** (wskorea26-pub-subnet-c 등) | `vpc.tf` | 각 `aws_subnet` 의 `tags.Name` |
| **AZ** (c, d) | `variables.tf` | `azs` 기본값. 채점 출력 순서(c→d) 주의 |
| **VPC 이름** (wskorea26-vpc) | `vpc.tf` | `aws_vpc.this` `tags.Name` |
| **라우트테이블 이름** | `vpc.tf` | `aws_route_table.*` 의 `tags.Name` |
| **IGW/NAT 이름** (book-igw, book-ngw-c/d) | `vpc.tf` | 각 리소스 `tags.Name` |
| 서브넷 **개수 증가** | `vpc.tf` | `aws_subnet` + RTB assoc 추가, `eks_nodegroups.tf` `subnet_ids` 반영 |

### 3-2. 이름·키 (서비스별)

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|-----------|-----------|-----------|
| **S3 버킷명** prefix (wskorea26-concert-bucket-) | `locals.tf` | `bucket_name` |
| **비번호** | `variables.tf` | `bi_number` (또는 `-var`) |
| **S3 객체 경로** (web/main/) | `s3.tf` | `aws_s3_object.index/main` 의 `key`, `cloudfront.tf` origin `origin_path` |
| **ECR 레포명** (wskorea26-book-repo) | `locals.tf` | `ecr_repo` |
| **이미지 태그** (stable) | `locals.tf` | `image_tag` |
| **DynamoDB 테이블명** | `locals.tf` | `table_name` |
| **DynamoDB 파티션키** (client_id) | `dynamodb.tf` | `hash_key` + `attribute` 블록 |
| **EKS 클러스터명** | `locals.tf` | `cluster_name` |
| **EKS 버전** (1.35) | `variables.tf` | `eks_version` |
| **EKS Subnet 지정** (priv c/d) | `eks.tf` | `aws_eks_cluster.this` `vpc_config.subnet_ids` |
| **네임스페이스** (wskorea26) | `locals.tf` | `namespace` |
| **노드그룹명/노드태그/라벨** | `eks_nodegroups.tf` | `local.node_groups` 맵 (`ng_name`/`node_name`/`label`) |
| **노드 인스턴스타입** (t3.medium) | `variables.tf` | `node_instance_type` |
| **Lambda 함수명/런타임** | `lambda.tf` | `aws_lambda_function.book` `function_name`/`runtime` |
| **CMK 별칭** (s3/dynamodb/eks-key) | `kms.tf` | 각 `aws_kms_alias.*` 의 `name` |

### 3-3. ALB / CloudFront (가장 까다로움)

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|-----------|-----------|-----------|
| **ALB 이름** (wskorea26-book-alb) | `alb.tf` | `aws_lb.book` `name` |
| **ALB 리스너 포트** (HTTP 80) | `alb.tf` | `aws_lb_listener.book` `port` |
| **라우팅 경로** (/book, /v1/book) | `alb.tf` | `aws_lb_listener_rule.*` `path_pattern`; `cloudfront.tf` 함수 + `ordered_cache_behavior.path_pattern` |
| **X-Origin-Verify 값** (wskorea26-cf) | `variables.tf` | `cf_origin_verify` (ALB 룰 + CF origin 헤더 동시 적용됨) |
| **S3 전달 헤더** (wskorea26-s3-access=true) | `variables.tf` / `cloudfront.tf` | `s3_access_header_value` / S3 origin `custom_header.name` |
| **CloudFront 이름**(Comment) | `cloudfront.tf` | `aws_cloudfront_distribution.this` `comment` |
| **Origin ID** (s3-origin/alb-origin) | `cloudfront.tf` | 각 `origin.origin_id` + behavior `target_origin_id` |
| **앱 내부 경로**가 /v1/book 이 아니게 바뀌면 | `cloudfront.tf` | `aws_cloudfront_function.book_rewrite` 의 재작성 규칙 |

> ⚠️ book 앱은 **`POST /v1/book` 와 `GET /health` 만** 처리한다(배포 바이너리 고정).
> 그래서 CloudFront `/book`(POST) → CloudFront Function 이 `/v1/book` 으로 재작성 →
> ALB 룰(POST)이 book Pod 로 포워딩한다. `GET /book` 은 ALB 룰(GET)이 Lambda 로 보낸다.
> 경로 요구사항이 바뀌면 **CF 함수 + ALB 룰 두 곳**을 같이 고쳐야 한다.

### 3-4. Lambda 조회 로직 / DynamoDB GSI

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|-----------|-----------|-----------|
| **조회 쿼리 파라미터** (concert_name) | `files/lambda_function.py` | `qs.get("concert_name")` + GSI hash_key |
| **정렬 기준** (created_at 최신순) | `dynamodb.tf` GSI `range_key` + `lambda_function.py` `ScanIndexForward` |
| **GSI 이름** | `locals.tf` | `gsi_name` (lambda env 로 주입됨, 하드코딩 아님) |
| **응답 형식** | `files/lambda_function.py` | `_resp()` / `handler()` |

### 3-5. 모니터링 / Grafana

| 바뀌는 값 | 수정 파일 | 수정 위치 |
|-----------|-----------|-----------|
| **대시보드 이름/uid** (wskorea26-monitoring/wskorea26) | `k8s/wskorea26-dashboard.json` | `title` / `uid` |
| **표시 지표(패널)** | `k8s/wskorea26-dashboard.json` | `panels[].targets[].expr` |
| **Grafana 관리자** (admin/wsk2026!) | `variables.tf` | `grafana_admin_user` / `grafana_admin_password` |
| **Grafana LB 이름** (wskorea26-grafana-alb) | `k8s/grafana-values.yaml.tftpl` | `aws-load-balancer-name` 어노테이션 |
| **모니터링 배치 노드** | `k8s/*-values.yaml.tftpl` | `nodeSelector.node-type` |

---

## 4. 채점 항목 대응 메모

- **1 Network**: CIDR/라우팅 → `vpc.tf`. private RTB 는 0.0.0.0/0=NAT 만, public 은 IGW.
- **2 S3**: 4종 PublicAccessBlock True + IsPublic False + 객체 KMS=`wskorea26-s3-key`.
- **3 ECR**: scanOnPush True / KMS / 태그 stable / Critical·High 0 (scratch 이미지).
- **4 DynamoDB**: client_id HASH / DeletionProtection True / `wskorea26-dynamodb-key`.
- **5 EKS**: v1.35 / 로그 5종(api,audit,authenticator,controllerManager,scheduler) /
  `wskorea26-eks-key` / subnet priv-c·priv-d / 노드 t3.medium·태그·node-type 라벨 / ns wskorea26.
- **6 Lambda**: python3.14 / TABLE_NAME=wskorea26-data-table.
- **7 ALB**: internet-facing / 80 HTTP / 룰 헤더 wskorea26-cf / 직접 /book 호출 403.
- **8 CloudFront**: S3 기본·ALB /book* / redirect-to-https / 커스텀헤더 / 200·301·main.jpeg(180926B).
- **9 Application**: CF 경유 POST·GET /book 동작.
- **10 Monitoring**: Grafana 로그인(admin/wsk2026!) 후 대시보드 지표 확인.

---

## 5. 주의/리스크 (apply 전 확인)

1. **비번호(`bi_number`) 반드시 설정** — 안 하면 버킷명이 `...-000` 이 된다.
2. **book 이미지 빌드는 docker 필요** — CloudShell 엔 없으니 docker 환경에서 빌드/푸시.
3. **created_at 정렬** — GSI(range=created_at)로 DB 레벨 최신순 정렬. 배포 book 앱이
   `created_at` 속성을 기록한다는 전제(Reference03). 미기록 시 조회 결과가 비어 보일 수 있음.
4. **Grafana LB** — Service type LoadBalancer 로 생성(AWS LB Controller). 채점 명령
   `kubectl get svc grafana -n monitoring` 로 주소 확인 가능하게 구성됨.
5. apply 후 CloudFront 배포(Deployed)까지 수 분 소요. 8-4 채점 전 Status 확인.
