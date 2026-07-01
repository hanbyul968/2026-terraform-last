# 2과제 (01) — Small Challenge

REST API / RDS Connection / Workflow / VPN. 4개 모듈, 멀티 리전.
**서버리스(module-1, module-3)는 로컬 PowerShell에서 바로 apply**, **VPC 모듈(module-2, module-4)은 Bastion(SSM) 안에서 apply**.

| 모듈 | 내용 | 리전 | apply 위치 |
|------|------|------|-----------|
| module-1 | REST API — DynamoDB `wsc2026-api-storage` / Lambda `wsc2026-api-handler`(py3.14) / API GW `wsc2026-rest-api` stage `V1` | ap-northeast-2 | **로컬** (서버리스) |
| module-2 | RDS — VPC `wsc2026-db-vpc` / MySQL 8.4.9 `wsc2026-rds-instance` / Secrets + RDS Proxy `wsc2026-rds-proxy` / Lambda `wsc2026-db-client`(pymysql layer) | ap-northeast-1 | **Bastion** (pymysql layer bash 빌드) |
| module-3 | Workflow — S3 `wsc2026-wf-inbound-bucket` + EventBridge `wsc2026-s3-trigger-rule` + Step Functions `wsc2026-wf-statemachine` + Lambda `wsc2026-transform-lambda` + DynamoDB `wsc2026-target-db` | us-east-1 | **로컬** (서버리스) |
| module-4 | VPN — VPC `wsc2026-vpn-vpc` / `vpn-ec2`(t3.micro) / Client VPN `wsc-vpn` 172.16.0.0/22 UDP1194 mutual-auth / 인증서 `cve.wsc`·`client.wsc` | ap-southeast-1 | Bastion (또는 로컬 가능, VPC 모듈이라 관례상 Bastion) |

> ⚠️ 실제 TF 는 **`module-1` ~ `module-4`** (하이픈). `module1`~`module4`(하이픈 없음) 는 빈 폴더 — 사용하지 않음.
> 리소스 이름/태그는 **문제지 리터럴 고정값**(대소문자 구분). 채점 스크립트가 이 이름 그대로 조회하므로 변경 금지.

---

## 방법 A — 서버리스 모듈은 로컬에서 바로 apply

module-1, module-3 은 VPC/EC2/Linux 의존이 없어 Windows PowerShell 에서 그대로 생성됩니다.

```powershell
cd C:\Users\competitor\2026-terraform\01\2과제\module-1   # ap-northeast-2
terraform init ; terraform apply -auto-approve

cd ..\module-3                                             # us-east-1
terraform init ; terraform apply -auto-approve
```

## 방법 B — VPC 모듈은 Bastion(SSM) 안에서 apply

module-2 는 pymysql Lambda Layer 를 `bash`(local-exec)로 빌드하므로 Linux Bastion 이 필요합니다.
module-4 도 VPC 모듈이라 Bastion 에서 함께 배포합니다. (module-1/3 도 deploy.sh 에 포함되어 전체 실행 가능)

```powershell
# 1) 로컬 — Bastion 생성 (전용 VPC 10.250.0.0/16, SSM 접속, 코드 번들 자동 업로드)
cd C:\Users\competitor\2026-terraform\01\2과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # 접속 명령 출력
```
```bash
# 2) SSM 접속 후 — 부트스트랩 완료 대기 → 4개 모듈 순차 apply
until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done
bash /opt/task2/deploy.sh        # module-1 → module-2 → module-3 → module-4
```

접속:
```powershell
aws ssm start-session --target <bastion-instance-id> --region ap-northeast-2
```

---

## 모듈별 검증 (채점기준표 v2 기준)

- **module-1**: `aws dynamodb describe-table --table-name wsc2026-api-storage` / `aws lambda invoke --function-name wsc2026-api-handler --payload '{"method":"GET","id":"..."}'` → **직접 호출은 raw item 반환**(2-3 채점 형식과 일치) / API POST `/items` 는 `{"message":"Item created successfully","id":...}`.
- **module-2**: RDS `available`, Proxy `available`, `db.t3.micro`/`mysql`/`8.4.9`/PublicAccess `False`. Lambda `wsc2026-db-client` `python3.14`, `{"action":"read","username":...}` 테스트.
- **module-3**: S3 EventBridge 알림 on, rule `ENABLED`, transform 테스트, DynamoDB `PAY_PER_REQUEST`, S3 put→SFN→DynamoDB 저장(11-1).
- **module-4**: VPC/서브넷 4개, `vpn-ec2` `t3.micro` running, ACM `cve.wsc`/`client.wsc`, VPN SSH 접속.

---

## 수동/후속 단계

- **module-4 VPN 접속 테스트(14-2)**: Client VPN 엔드포인트에서 `.ovpn` 클라이언트 설정 다운로드 → 클라이언트 인증서/키 삽입 → OpenVPN 접속 → `vpn-ec2` private IP 로 SSH.
  - SSH 키는 apply 시 자동 생성됩니다: `module-4/vpn-ec2-key.pem` (또는 `terraform output -raw ssh_private_key_pem > key.pem`).
  - 클라이언트 인증서/키: `terraform output client_certificate_pem` / `terraform output -raw client_private_key_pem`.
  - 접속: `ssh -i module-4/vpn-ec2-key.pem ec2-user@$(terraform output -raw vpn_ec2_private_ip)`
- **module-2 users 테이블**: `ensure_schema()` 가 첫 호출 시 `data` DB + `users` 테이블(DDL)을 자동 생성. read 테스트 전 필요 시 `{"action":"create","username":"test_user","role":"viewer"}` 로 시딩.

---

## Destroy 순서

```powershell
# 로컬에서 생성한 서버리스 모듈
cd module-3 ; terraform destroy -auto-approve
cd ..\module-1 ; terraform destroy -auto-approve
```
```bash
# Bastion 안에서 생성한 VPC 모듈
cd /opt/task2/module-4 ; terraform destroy -auto-approve
cd /opt/task2/module-2 ; terraform destroy -auto-approve
```
```powershell
# 마지막에 Bastion(+부트스트랩 버킷) 제거 — module-* 와 state 분리됨
cd C:\Users\competitor\2026-terraform\01\2과제\bastion ; terraform destroy -auto-approve
```

> module-1(deletion protection ON DynamoDB)은 destroy 시 `deletion_protection_enabled=false` 로 바꾼 뒤 apply→destroy 하거나 콘솔에서 보호 해제 후 삭제.

---

## 비고
- 이 대회 계정엔 **default VPC 가 없음** → bastion 은 전용 VPC(`10.250.0.0/16` + public subnet + IGW + route)를 스스로 생성 (`bastion/main.tf`, 이미 반영됨).
- Lambda 런타임 `python3.14` (aws provider 6.x).
- 검증: bastion·module-1·module-2·module-3·module-4 모두 `terraform validate` 통과.
