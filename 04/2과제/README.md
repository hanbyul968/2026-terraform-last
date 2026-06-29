# 2과제 (04) — Small Challenge

EKS Scaling / VPC Lattice / Container Logging / REST API. **로컬 PowerShell에서 Bastion을 띄우고, 나머지는 Bastion(Linux)에서 apply**한다.

| 모듈 | 내용 | 리전 |
|------|------|------|
| module1 | EKS Scaling (KEDA + Karpenter, SQS) | ap-northeast-2 |
| module2 | VPC Lattice (Hub/Spoke, header+weighted routing) | ap-southeast-1 |
| module3 | Container logging (EKS + Loki + Grafana, EC2 docker flask + Fluent Bit) | ap-northeast-1 |
| module4 | REST API (API Gateway + Lambda py3.14 + DynamoDB) | us-east-1 |

## 실행
```powershell
# 1) 로컬 PowerShell — Bastion 생성
cd C:\Users\competitor\2026-terraform\04\2과제\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # 접속 명령

# 2) Bastion 접속 (SSM)
aws ssm start-session --target <id> --region ap-northeast-2
```
```bash
# 3) Bastion 안에서 — 전체 배포
until [ -f /opt/task2/READY ]; do sleep 5; done
bash /opt/task2/deploy.sh     # module1..4 + KEDA/Karpenter + Loki/Grafana
```
채점 후 로컬에서 `cd bastion; terraform destroy -auto-approve` 로 Bastion만 제거.

## 배포파일
- module2: `module2/app/version1.py`,`version2.py` (TCP8080, /version, /healthcheck) — 지급 배포파일로 교체. 없으면 user_data 의 내장 최소 앱 사용.
- module3: `module3/app/app.py`,`Dockerfile`,`requirements.txt` (flask wsc-log-app:5000) — 지급 배포파일을 EC2(wsc-logging-app-bastion)에 배치 후 docker 빌드/실행 + Fluent Bit(systemd)로 Loki NLB 전송.

## 비번호 치환
- module1/module3 의 비번호 종속 값 없음(고정 이름). 
- module3 `manifest/grafana-values.yaml` 의 adminUser=`wsc2026-admin-<비번호>`, adminPassword=`admin<비번호>!` — 본인 번호로 치환.

## 검증 상태
모든 모듈 + bastion `terraform validate` 통과. 실제 apply(EKS/KEDA/Karpenter/Lattice/Loki)는 환경에서 1회 수행 필요.

## NEEDS-REVIEW
- Karpenter Helm 차트는 버전 핀이 필요할 수 있음(deploy.sh가 latest OCI 설치 시도, 실패 시 `manifest/karpenter.yaml`만 적용). 
- module3 app EC2 의 Fluent Bit→Loki 전송은 Loki NLB 주소 확정 후 SSM으로 기동(자동화는 deploy.sh 주석 참고).
- KEDA `identityOwner: operator` (IRSA: wsc-scaling-keda-role) 사용.


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\04\2과제\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.
