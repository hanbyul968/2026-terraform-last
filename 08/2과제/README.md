# 2과제: Small Challenge (Terraform)

**반드시 CloudShell에서 실행하세요.**

---

## 실행 순서

### 1. Terraform 설치

```bash
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform
```

### 2. 코드 다운로드

```bash
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/08/2과제
```

### 3. 배포

```bash
terraform init
terraform apply -var="team_id=<비번호>" -auto-approve
```

> 소요 시간: Aurora Serverless v2 약 10분, CloudFront 약 3분

### 4. Module 1 - result.json 생성 (채점 필수)

```bash
bash files/nosql/query.sh electronics
cat ~/result.json
```

### 5. Module 3 - Step Functions 실행 (채점 필수)

```bash
SFN_ARN=$(aws stepfunctions list-state-machines \
  --region ap-southeast-1 \
  --query "stateMachines[?name=='workflow-state-machine'].stateMachineArn | [0]" \
  --output text)

aws stepfunctions start-execution \
  --region ap-southeast-1 \
  --state-machine-arn $SFN_ARN \
  --input '{"bucket":"workflow-input-<비번호>","key":"data.csv"}'

sleep 30

aws dynamodb scan \
  --table-name workflow-output \
  --region ap-southeast-1 \
  --select COUNT
```

> Count >= 1 이면 정상

### 6. 동작 확인

```bash
# Module 2: X-Custom-Header 확인
CF=$(terraform output -raw m2_cloudfront_domain)
curl -sI "https://$CF/index.html?v=1" | grep -i X-Custom-Header
# 결과: X-Custom-Header: wsc2026

# Module 4: Lambda 실행
aws lambda invoke \
  --function-name rds-query-function \
  --region ap-northeast-3 \
  response.json
cat response.json
```

### 7. 삭제

```bash
terraform destroy -var="team_id=<비번호>" -auto-approve
```

---

## 주의사항

- **반드시 CloudShell(Linux)에서 실행하세요.** Windows에서 실행하면 `null_resource.sfn_execute`의 `/bin/bash`를 찾지 못해 실패합니다.
- **`insert.sh`를 따로 실행하지 마세요.** 이 테라폼이 `aws_dynamodb_table_item`으로 20건을 직접 삽입합니다. 같이 돌리면 `ConditionalCheckFailedException`(중복 삽입) 충돌이 납니다. apply 후에는 `query.sh`만 실행해 `result.json`을 만드세요.
- apply가 중간에 실패한 뒤 재실행하면 state와 실제 AWS 리소스가 어긋나 `already exists`(409) 충돌이 날 수 있습니다. 아래 트러블슈팅 참고.

---

## 트러블슈팅 — `already exists` / `ConditionalCheckFailed` 충돌

이전 apply가 중간에 깨져 리소스는 AWS에 남았지만 state에는 없는 경우 발생합니다. **고아 리소스를 정리한 뒤 재배포**합니다.

### 1. state에 있는 것 먼저 정리

```bash
terraform destroy -var="team_id=<비번호>" -auto-approve
```

### 2. destroy가 못 지운 고아 리소스 수동 삭제 (리전별)

```bash
# --- ap-northeast-2 : DynamoDB 테이블 (아이템 포함 삭제) ---
aws dynamodb delete-table --table-name nosql-products --region ap-northeast-2

# --- us-east-1 : CloudFront OAC ---
OAC_ID=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='cdn-oac'].Id | [0]" --output text)
if [ "$OAC_ID" != "None" ] && [ -n "$OAC_ID" ]; then
  ETAG=$(aws cloudfront get-origin-access-control --id $OAC_ID --query ETag --output text)
  aws cloudfront delete-origin-access-control --id $OAC_ID --if-match $ETAG
fi

# --- us-east-1 : CloudFront Function ---
FN_ETAG=$(aws cloudfront describe-function --name cdn-add-security-header --query ETag --output text 2>/dev/null)
[ -n "$FN_ETAG" ] && aws cloudfront delete-function --name cdn-add-security-header --if-match $FN_ETAG

# --- ap-southeast-1 : Lambda ---
aws lambda delete-function --function-name workflow-transform --region ap-southeast-1

# --- ap-northeast-3 : Aurora (서브넷 그룹보다 먼저 삭제해야 함) ---
aws rds delete-db-instance --db-instance-identifier rds-aurora-cluster-instance-1 \
  --skip-final-snapshot --region ap-northeast-3
aws rds wait db-instance-deleted --db-instance-identifier rds-aurora-cluster-instance-1 --region ap-northeast-3
aws rds delete-db-cluster --db-cluster-identifier rds-aurora-cluster \
  --skip-final-snapshot --region ap-northeast-3
aws rds wait db-cluster-deleted --db-cluster-identifier rds-aurora-cluster --region ap-northeast-3
aws rds delete-db-subnet-group --db-subnet-group-name rds-aurora-subnet-group --region ap-northeast-3
aws secretsmanager delete-secret --secret-id rds/aurora/admin \
  --force-delete-without-recovery --region ap-northeast-3
```

> `DBSubnetGroupAlreadyExists` 삭제 시 `InvalidDBSubnetGroupStateFault`가 나면 Aurora 인스턴스/클러스터가 아직 살아있는 것입니다. 위 순서대로 인스턴스 → 클러스터 → 서브넷 그룹 순으로 삭제하세요.

### 3. 중복 VPC 확인 (감점 예방)

VPC/서브넷은 이름 충돌이 안 나 재apply 시 **중복 생성**될 수 있습니다.

```bash
aws ec2 describe-vpcs --region ap-northeast-3 \
  --filters "Name=tag:Name,Values=rds-aurora-vpc" \
  --query "Vpcs[].VpcId" --output text
```

2개 이상이면 고아 VPC를 삭제하세요 (state에 없는 것).

### 4. 깨끗하게 재배포

```bash
terraform apply -var="team_id=<비번호>" -auto-approve
```

---

## 모듈 구성

| 모듈 | 리전 | 리소스 |
|------|------|--------|
| 1 NoSQL | ap-northeast-2 | DynamoDB `nosql-products` + GSI + 20건 + `~/result.json` |
| 2 CDN | us-east-1 | S3 `cdn-static-<비번호>` + CloudFront + OAC + Function |
| 3 Workflow | ap-southeast-1 | S3 + Lambda `workflow-transform` + DynamoDB `workflow-output` + Step Functions |
| 4 RDS | ap-northeast-3 | Aurora MySQL Serverless v2 + Data API + Secret `rds/aurora/admin` + Lambda |

---

## 값 변경 시 수정 위치

### 공통

| 변경 항목 | 파일 | 수정 위치 |
|-----------|------|-----------|
| 리전 (Module 1) | `providers.tf` | `aws.seoul` → `region` |
| 리전 (Module 2) | `providers.tf` | `aws.use1` → `region` |
| 리전 (Module 3) | `providers.tf` | `aws.sg` → `region` |
| 리전 (Module 4) | `providers.tf` | `aws.osaka` → `region` |

### Module 1 - NoSQL

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| 테이블 이름 | `module1_nosql.tf` | `aws_dynamodb_table.products` → `name` | `"nosql-products"` |
| Partition Key | `module1_nosql.tf` | `hash_key` + `attribute { name }` (2곳) | `"product_id"` |
| Sort Key | `module1_nosql.tf` | `range_key` + `attribute { name }` (2곳) | `"category"` |
| GSI 이름 | `module1_nosql.tf` | `global_secondary_index { name }` | `"category-price-index"` |
| GSI Partition Key | `module1_nosql.tf` | `global_secondary_index { hash_key }` + `attribute { name }` | `"category"` |
| GSI Sort Key | `module1_nosql.tf` | `global_secondary_index { range_key }` + `attribute { name }` | `"price"` |
| Stream 뷰 타입 | `module1_nosql.tf` | `stream_view_type` | `"NEW_AND_OLD_IMAGES"` |
| 샘플 데이터 | `module1_nosql.tf` | `locals { nosql_products = [ ... ] }` | P001~P020 20건 |
| query.sh 조회 카테고리 | 실행 명령 인자 | `bash files/nosql/query.sh <카테고리>` | `electronics` |

### Module 2 - CDN

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| S3 버킷 이름 접두사 | `module2_cdn.tf` | `locals { cdn_bucket }` | `"cdn-static-${var.team_id}"` |
| CloudFront Comment | `module2_cdn.tf` | `aws_cloudfront_distribution.cdn` → `comment` | `"cdn-${var.team_id}"` |
| Default Root Object | `module2_cdn.tf` | `default_root_object` | `"index.html"` |
| OAC 이름 | `module2_cdn.tf` | `aws_cloudfront_origin_access_control.cdn` → `name` | `"cdn-oac"` |
| Function 이름 | `module2_cdn.tf` | `aws_cloudfront_function.security_header` → `name` | `"cdn-add-security-header"` |
| 응답 헤더 이름 | `files/cdn/cdn-add-security-header.js` | `response.headers['<헤더명>']` | `'x-custom-header'` |
| 응답 헤더 값 | `files/cdn/cdn-add-security-header.js` | `{ value: '<값>' }` | `'wsc2026'` |
| 업로드 파일 목록 | `module2_cdn.tf` | `locals { cdn_files = { ... } }` | `index.html, style.css, image.png` |

### Module 3 - Workflow

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| S3 버킷 이름 접두사 | `module3_workflow.tf` | `locals { workflow_bucket }` | `"workflow-input-${var.team_id}"` |
| DynamoDB 테이블 이름 | `module3_workflow.tf` | `locals { workflow_table }` | `"workflow-output"` |
| Lambda 함수 이름 | `module3_workflow.tf` | `aws_lambda_function.workflow_transform` → `function_name` | `"workflow-transform"` |
| Lambda Timeout | `module3_workflow.tf` | `timeout` | `60` |
| Lambda Runtime | `module3_workflow.tf` | `runtime` | `"python3.12"` |
| Step Functions 이름 | `module3_workflow.tf` | `aws_sfn_state_machine.workflow` → `name` | `"workflow-state-machine"` |
| Step Functions 유형 | `module3_workflow.tf` | `type` | `"STANDARD"` |

> DynamoDB 테이블 이름 변경 시 `locals { workflow_table }` 한 곳만 수정하면 Lambda 환경변수 `TABLE_NAME`까지 자동 반영

### Module 4 - RDS Connection

| 변경 항목 | 파일 | 수정 위치 | 현재 값 |
|-----------|------|-----------|---------|
| 클러스터 이름 | `module4_rds.tf` | `locals { rds_cluster_name }` | `"rds-aurora-cluster"` |
| DB 이름 | `module4_rds.tf` | `locals { rds_db_name }` | `"appdb"` |
| 마스터 사용자 | `module4_rds.tf` | `locals { rds_master_user }` | `"admin"` |
| Secret 이름 | `module4_rds.tf` | `locals { rds_secret_name }` | `"rds/aurora/admin"` |
| Aurora 엔진 버전 | `module4_rds.tf` | `data.aws_rds_engine_version` → `preferred_versions` | `3.08.0, 3.07.1, 3.07.0` |
| Aurora ACU 범위 | `module4_rds.tf` | `serverlessv2_scaling_configuration` | `min=0.5, max=4` |
| Lambda 함수 이름 | `module4_rds.tf` | `aws_lambda_function.rds_query` → `function_name` | `"rds-query-function"` |
| Lambda Runtime | `module4_rds.tf` | `runtime` | `"python3.12"` |
| RDS VPC CIDR | `module4_rds.tf` | `aws_vpc.rds` → `cidr_block` | `"10.20.0.0/16"` |

> DB 이름 / Secret 이름 변경 시 `locals { }` 한 곳만 수정하면 클러스터, Secret JSON, Lambda 환경변수까지 자동 반영
