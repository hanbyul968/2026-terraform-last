# 2과제: Small Challenge (Terraform)

**배포는 Bastion EC2(Linux)에서, 채점·검증은 CloudShell에서 합니다.**

> 📍 **왜 Bastion?** 이 테라폼의 `null_resource.sfn_execute`가 `/bin/bash`에 의존하므로
> 로컬 윈도우에서 직접 `apply` 하면 실패합니다. 그래서 **로컬 윈도우(PowerShell)** 에서 Bastion EC2를
> 먼저 띄우고, **Bastion(Amazon Linux)** 에 접속해 4개 모듈을 배포합니다.
> Bastion은 인스턴스 프로파일(권한)을 쓰므로 **IAM User AccessKey가 필요 없습니다.**
>
> **흐름:** 로컬 윈도우(PowerShell)에서 ①Bastion 생성 → ②Bastion 접속 → ③Bastion에서 배포 → CloudShell에서 채점/검증

---

## A. 로컬 윈도우(PowerShell)에서 — Bastion 생성

> 📍 내 PC의 **PowerShell**. AWS CLI가 설치·구성(`aws configure`)돼 있어야 합니다.
> SSM 접속을 위해 [Session Manager 플러그인](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)도 설치하세요.

```powershell
cd 2026-terraform\08\2과제\bastion
terraform init
terraform apply -auto-approve
```

apply가 끝나면 접속 명령이 출력됩니다:

```powershell
terraform output -raw ssm_connect_command
# 예) aws ssm start-session --target i-0abc... --region ap-northeast-2
```

## B. 로컬 윈도우(PowerShell)에서 — Bastion 접속

> 📍 내 PC의 **PowerShell**. user_data로 git·terraform 설치가 끝날 때까지 부팅 후 1~2분 대기.

```powershell
aws ssm start-session --target <위에서 출력된 인스턴스 ID> --region ap-northeast-2
```

접속하면 프롬프트가 Bastion(`sh-5.2$`)으로 바뀝니다. 이후 **C~F는 모두 Bastion 안에서** 실행합니다.

## C. Bastion에서 — 코드 다운로드 & 배포

> 📍 **Bastion 쉘.** terraform/git은 부팅 시 자동 설치됨 (`terraform -version`으로 확인).

```bash
sudo su -                     # 편의상 루트로 전환 (선택)
git clone https://github.com/hnmly/2026-terraform.git
cd 2026-terraform/08/2과제
terraform init
terraform apply -var="team_id=<비번호>" -auto-approve
```

> 소요 시간: Aurora Serverless v2 약 10분, CloudFront 약 3분
> **이후 D~F는 전부 이 `2과제` 디렉터리 안에서** 실행하세요 (`bash files/...`, `terraform output`이 상대경로·state 참조).

## D. Bastion에서 — Module 1 result.json 생성 (채점 필수)

> 📍 **Bastion 쉘**, `2과제` 디렉터리 (apply 완료 후).

```bash
bash files/nosql/query.sh electronics
cat ~/result.json
```

## E. Bastion에서 — Module 3 Step Functions 실행 (채점 필수)

> 📍 **Bastion 쉘**, `2과제` 디렉터리. `<비번호>`는 본인 번호로.

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

## F. Bastion에서 — 동작 확인

> 📍 **Bastion 쉘**, `2과제` 디렉터리 (`terraform output` 사용 때문).

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

## G. CloudShell에서 — 채점

> 📍 **CloudShell** (AWS Console 우측 상단 `>_` 아이콘). 채점 규칙상 채점은 CloudShell에서 진행합니다.
> 배포는 Bastion에서 끝났으므로, CloudShell에서는 채점 스크립트만 실행합니다.

```bash
bash grade_module1_v2.sh
bash grade_module2_v2.sh
bash grade_module3_v2.sh
bash grade_module4_v2.sh
```

## H. 정리 (채점 후)

```bash
# 1) Bastion 쉘, 2과제 디렉터리 — 4개 모듈 삭제
terraform destroy -var="team_id=<비번호>" -auto-approve
exit   # Bastion 세션 종료

# 2) 로컬 윈도우(PowerShell), bastion 디렉터리 — Bastion EC2 삭제
cd 2026-terraform\08\2과제\bastion
terraform destroy -auto-approve
```

---

## 주의사항

- **로컬 윈도우에서 4개 모듈을 직접 `apply` 하지 마세요.** `null_resource.sfn_execute`의 `/bin/bash`를 못 찾아 실패합니다. 반드시 Bastion(Linux)에서 배포하세요.
- **채점은 CloudShell에서** 진행합니다 (채점 규칙). 배포 위치(Bastion)와 채점 위치(CloudShell)가 다른 점에 유의하세요.
- **Bastion은 배포용 임시 리소스**입니다. 4개 모듈 채점이 끝나면 H의 순서대로 Bastion까지 삭제하세요. (Bastion의 main terraform state는 Bastion 안에 있으므로, 모듈 destroy를 먼저 한 뒤 Bastion을 삭제)
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

> 위 4개 모듈 = 채점 대상. **Bastion**(`bastion/` 폴더)은 배포용 임시 EC2로 채점 대상이 아니며, 별도 state로 관리됩니다.

### Bastion 설정 변경 (`bastion/main.tf`)

| 변경 항목 | 수정 위치 | 현재 값 |
|-----------|-----------|---------|
| Bastion 리전 | `provider "aws"` → `region` | `"ap-northeast-2"` |
| 인스턴스 타입 | `aws_instance.bastion` → `instance_type` | `"t3.small"` |
| 접속 방식 | SSM Session Manager (키페어/22번 포트 없음) | — |
| 권한 | `aws_iam_role_policy_attachment.admin` (AdministratorAccess) | — |

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


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\08\2과제\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.
