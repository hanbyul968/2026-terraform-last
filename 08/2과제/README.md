# 2과제: Small Challenge (Terraform) — 08

4개 모듈(NoSQL / CDN / Workflow / RDS Connection)을 Terraform 으로 배포한다.
**채점은 CloudShell 에서** `grade_module1_v2.sh ~ grade_module4_v2.sh` 로 수행하며,
**Bastion 은 채점에 사용하지 않는다**(채점지 유의사항).

## 아키텍처 (로컬 vs Bastion)

| 대상 | 위치(폴더) | 리전 | 배포 방법 | 비고 |
|------|-----------|------|-----------|------|
| **루트(서버리스 3개)** Module1/2/3 | `08/2과제` (루트 `*.tf`) | 서울/버지니아/싱가포르 | **로컬 Windows `terraform apply`** | VPC 불필요 → Linux 의존성 없음 |
| **Module4 RDS** | `08/2과제/module4_rds` | 오사카 | **Bastion(Linux)** 또는 로컬 | 전용 VPC 생성(Aurora Serverless v2) |
| Bastion(배포 전용 EC2) | `08/2과제/bastion` | 서울 | 로컬 Windows `terraform apply` | 채점 대상 아님, 별도 state |

> 💡 **왜 이렇게 나눴나?**
> 루트 3개 모듈은 순수 서버리스(DynamoDB/S3/CloudFront/Lambda/Step Functions)라 **Windows 로컬에서 바로 `apply`** 하면 전부 생성된다(Linux/bash 의존 provisioner 제거됨).
> Module4 는 전용 VPC + Aurora Serverless v2 를 만들므로 **Bastion(Linux)** 에서 배포하는 흐름을 기본으로 한다(로컬에서도 가능).
> Step Functions **실행**과 `result.json` **생성**은 인프라가 아닌 런타임 동작이라 CloudShell/Bastion(Linux) 에서 수행한다(문제·채점 지침과 동일).

---

## 모듈 구성 / 리전 / 리소스 이름

| 모듈 | 리전 | 주요 리소스 (이름) | 배점 |
|------|------|--------------------|------|
| 1 NoSQL | ap-northeast-2 | DynamoDB `nosql-products` (PK `product_id`, SK `category`, On-Demand) + GSI `category-price-index`(HASH `category`, RANGE `price`) + Streams + 20건 + `~/result.json` | 7.5 |
| 2 CDN | us-east-1 | S3 `cdn-static-<비번호>`(퍼블릭 차단) + CloudFront(comment `cdn-<비번호>`, root `index.html`) + OAC `cdn-oac` + Function `cdn-add-security-header`(Viewer Response, `X-Custom-Header: wsc2026`) | 7.5 |
| 3 Workflow | ap-southeast-1 | S3 `workflow-input-<비번호>`(+data.csv) + DynamoDB `workflow-output`(PK `id`, On-Demand) + Lambda `workflow-transform`(py3.12, timeout 60, env `TABLE_NAME`) + Step Functions `workflow-state-machine`(STANDARD) | 7.5 |
| 4 RDS | ap-northeast-3 | Aurora MySQL Serverless v2 `rds-aurora-cluster`(0.5~4 ACU, DB `appdb`, admin) + Data API(HTTP Endpoint) + Secret `rds/aurora/admin` + Lambda `rds-query-function`(py3.12, VPC 없음) | 7.5 |

**합계 30점.** 모든 이름/태그/환경변수는 대소문자를 구분한다.

---

## 비번호(team_id) 치환 지점

`<비번호>`(team_id)는 소문자/숫자/하이픈만 사용(S3 버킷 규칙). 아래에서만 쓰인다.

| 위치 | 용도 |
|------|------|
| 루트 `apply -var="team_id=<비번호>"` | `cdn-static-<비번호>`, `workflow-input-<비번호>` 버킷명 |
| Bastion `apply -var="team_id=<비번호>"` | deploy.sh 가 루트 apply / SFN 입력에 전달 |
| SFN 실행 입력 `workflow-input-<비번호>` | Module3 데이터 적재 |

> Module1/4 는 이름이 고정(`nosql-products`, `rds-aurora-cluster` 등)이라 비번호 치환이 없다.

---

## 경로 A — 로컬 Windows(PowerShell)에서 서버리스 3개 배포 (권장)

> 📍 내 PC의 **PowerShell**. `aws configure` 완료 상태.

```powershell
cd C:\Users\competitor\2026-terraform\08\2과제
terraform init
terraform apply -var="team_id=<비번호>" -auto-approve
```

- 생성: Module1 NoSQL(+20건), Module2 CDN, Module3 Workflow(상태 머신까지).
- CloudFront 배포 완료까지 최대 3분.

### Module3 Step Functions 실행 (채점 3-5 필수)

> 인프라 생성 후, 데이터 적재를 위해 상태 머신을 1회 실행한다. CloudShell 또는 Bastion(Linux)에서:

```bash
SFN_ARN=$(aws stepfunctions list-state-machines --region ap-southeast-1 \
  --query "stateMachines[?name=='workflow-state-machine'].stateMachineArn | [0]" --output text)
aws stepfunctions start-execution --region ap-southeast-1 \
  --state-machine-arn "$SFN_ARN" \
  --input '{"bucket":"workflow-input-<비번호>","key":"data.csv"}'
sleep 20
aws dynamodb scan --table-name workflow-output --region ap-southeast-1 --select COUNT   # Count>=1
```

### Module1 result.json 생성 (채점 1-5 필수)

> CloudShell(권장) 또는 Bastion 에서. `files/nosql/query.sh` 는 지급 파일.

```bash
cd 08/2과제 ; bash files/nosql/query.sh electronics ; cat ~/result.json
```

---

## 경로 B — Module4 RDS 배포 (Bastion 권장)

### B-1. 로컬 PowerShell — Bastion 생성

```powershell
cd C:\Users\competitor\2026-terraform\08\2과제\bastion
terraform init
terraform apply -var="team_id=<비번호>" -auto-approve
terraform output -raw ssm_connect_command   # 접속 명령 확인
```

- 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 + IGW, SSM 전용(인바운드 0, 아웃바운드 443).
- 상위 `2과제` 코드 전체를 부트스트랩 S3 에 번들 업로드 → user_data 가 `/opt/task2` 에 풀고 `deploy.sh` 생성.

### B-2. 로컬 PowerShell — Bastion 접속 (SSM)

```powershell
aws ssm start-session --target <인스턴스 ID> --region ap-northeast-2
```

### B-3. Bastion 안에서 — 전체 배포(one-shot)

> 부팅 후 1~3분 대기(도구 설치·번들 준비). `deploy.sh` 는 루트(서버리스 3개) → module4_rds → SFN 실행 → result.json 을 순서대로 수행한다.

```bash
until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done
bash /opt/task2/deploy.sh <비번호>
```

> 로컬(경로 A)에서 서버리스 3개를 이미 배포했다면, Bastion 에선 **module4_rds 만** 따로 돌려도 된다:
> ```bash
> cd /opt/task2/module4_rds && terraform init && terraform apply -auto-approve
> ```
> ⚠️ **경로 A(로컬)와 deploy.sh(Bastion) 를 둘 다 루트에 적용하지 말 것** — 같은 리소스 중복 생성/`already exists` 충돌 원인.

### Module4 동작 확인

```bash
aws lambda invoke --function-name rds-query-function --region ap-northeast-3 response.json
cat response.json
```

---

## 채점 (CloudShell)

```bash
bash grade_module1_v2.sh
bash grade_module2_v2.sh
bash grade_module3_v2.sh
bash grade_module4_v2.sh
```

- Module2 X-Custom-Header 확인: `curl -sI "https://<CloudFront Domain>/index.html?v=1" | grep X-Custom-Header` → `X-Custom-Header: wsc2026`

---

## 정리(destroy) — 순서 주의

```powershell
# 1) module4_rds 먼저 (Aurora 인스턴스→클러스터→서브넷그룹 순으로 삭제됨)
cd C:\Users\competitor\2026-terraform\08\2과제\module4_rds
terraform destroy -auto-approve          # 또는 Bastion 안 /opt/task2/module4_rds 에서

# 2) 루트 서버리스 3개
cd C:\Users\competitor\2026-terraform\08\2과제
terraform destroy -var="team_id=<비번호>" -auto-approve

# 3) 마지막으로 Bastion (별도 state → 부트스트랩 버킷까지 제거)
cd C:\Users\competitor\2026-terraform\08\2과제\bastion
terraform destroy -var="team_id=<비번호>" -auto-approve
```

> Bastion 안에서 배포했다면 module4_rds/루트 destroy 도 Bastion 안에서 먼저 수행한 뒤, 로컬에서 Bastion 을 destroy 한다.

---

## 값 변경 시 수정 위치

| 변경 항목 | 파일 | 위치 |
|-----------|------|------|
| Module1 테이블/PK/SK/GSI | `module1_nosql.tf` | `aws_dynamodb_table.products` |
| Module1 샘플 20건 | `module1_nosql.tf` | `locals.nosql_products` |
| Module2 버킷/Comment/OAC/Function | `module2_cdn.tf` | 각 리소스 |
| Module2 헤더 이름/값 | `files/cdn/cdn-add-security-header.js` | `x-custom-header` / `wsc2026` |
| Module3 버킷/테이블/Lambda/SFN | `module3_workflow.tf` | `locals` + 각 리소스 |
| Module4 클러스터/DB/Secret/엔진버전/ACU/Lambda | `module4_rds/main.tf` | `locals` + 각 리소스 |
| 리전(Module1/2/3) | `providers.tf` | `aws.seoul` / `aws.use1` / `aws.sg` |
| 리전(Module4) | `module4_rds/main.tf` | `provider "aws" { region }` |
| Bastion 리전/타입 | `bastion/variables.tf` | `region` / `instance_type` |

### 지급 파일(files/)

- `files/nosql/insert.sh`, `query.sh` : Module1 데이터 삽입/조회(테라폼이 20건을 직접 삽입하므로 채점 시 `query.sh` 만 실행)
- `files/cdn/index.html, style.css, image.png, cdn-add-security-header.js` : Module2 정적 파일 + Function 코드
- `files/workflow/lambda_function.py, data.csv` : Module3 Lambda 소스 + 입력 CSV
- `files/rds/lambda_function.py` (및 `module4_rds/files/rds/`) : Module4 Lambda 소스

> ⚠️ `insert.sh` 를 따로 실행하지 말 것 — 테라폼이 `aws_dynamodb_table_item` 으로 20건을 삽입하므로 중복 삽입(`ConditionalCheckFailed`) 충돌이 난다. apply 후에는 `query.sh` 로 `result.json` 만 생성.

---

## Secrets Manager 참고 (Module4)

문제는 "마스터 암호 Secrets Manager 관리"를 요구하고, 채점은 `describe-secret --secret-id rds/aurora/admin` 존재만 확인한다.
AWS 완전자동관리(`manage_master_user_password`)는 이름을 `rds/aurora/admin` 으로 지정할 수 없어 채점 이름과 어긋나므로,
`random_password` + `aws_secretsmanager_secret`(이름 `rds/aurora/admin`) 으로 직접 구성해 채점 이름을 만족시킨다.
