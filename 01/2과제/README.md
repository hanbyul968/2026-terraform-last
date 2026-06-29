# 2과제 (01) — Small Challenge

REST API / RDS Connection / Workflow / VPN. **로컬 PowerShell에서 Bastion → SSM → Bastion에서 모듈 순차 apply**.

| 모듈 | 내용 | 리전 |
|------|------|------|
| module-1 | REST API (DynamoDB wsc2026-api-storage / Lambda wsc2026-api-handler py3.14 / API GW wsc2026-rest-api stage V1) | ap-northeast-2 |
| module-2 | RDS (wsc2026-db-vpc / MySQL 8.4.9 wsc2026-rds-instance / Secrets + RDS Proxy wsc2026-rds-proxy / Lambda wsc2026-db-client) | ap-northeast-1 |
| module-3 | Workflow (S3 wsc2026-wf-inbound-bucket + EventBridge wsc2026-s3-trigger-rule + Lambda wsc2026-transform-lambda + DynamoDB wsc2026-target-db) | us-east-1 |
| module-4 | VPN (wsc2026-vpn-vpc / vpn-ec2 / Client VPN wsc-vpn 172.16.0.0/22 UDP1194 mutual-auth / cve.wsc·client.wsc) | ap-southeast-1 |

> ⚠️ 모듈 디렉터리는 **`module-1` ~ `module-4`** (하이픈) 가 실제 TF 입니다. `module1`~`module4`(하이픈 없음) 는 빈 폴더이니 사용하지 않습니다.

## 🚀 Apply — 2단계 (로컬 PowerShell → Bastion)

```powershell
# 1) 로컬 — Bastion 생성
cd C:\Users\competitor\2026-terraform\01\2과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command
```
```bash
# 2) SSM 접속 후 — module-1 → module-4 순차 apply
until [ -f /opt/task2/READY ]; do sleep 5; done
bash /opt/task2/deploy.sh
```
```powershell
# 3) 채점 후 — Bastion 제거 (모듈은 각 디렉터리에서 별도 destroy)
cd C:\Users\competitor\2026-terraform\01\2과제\bastion ; terraform destroy -auto-approve
```

## 검증 / 비고
- module-1~4 모두 `terraform validate` 통과, 채점기준표(과제지 v2 기준) 리터럴과 일치 확인됨.
- Lambda 런타임 python3.14 (aws provider 6.x).
- ⚠️ **default VPC 없음**: `bastion/main.tf` 가 default VPC 를 참조하면 `Error: no matching EC2 VPC found`. 전용 VPC(10.250.0.0/16 + public subnet + IGW + route)로 교체 필요(01/1과제 bastion 참고).
- module-4 Client VPN 은 ACM 자체서명 인증서(cve.wsc/client.wsc) 사용 — 클라이언트 .ovpn 다운로드 후 접속 검증.
