# 2과제 (02) — Small Challenge

학생성적 Workflow / 실시간 분석(Kinesis+Flink) / Cloud Event Handling / MSK. **로컬 PowerShell에서 Bastion → SSM → Bastion에서 모듈 apply**.

| 모듈 | 내용 | 리전 |
|------|------|------|
| module1 | Workflow: S3/Lambda/DynamoDB/StepFunctions (학생 성적) | ap-southeast-1 |
| module2 | Real-time analytics: VPC/EC2/ALB/Kinesis/Managed Flink Studio | ap-northeast-2 |
| module3 | Cloud event handling: EventBridge/CloudTrail/Lambda/SNS | eu-west-1 |
| module4 | MSK: VPC/MSK(IAM)/Producer EC2/Consumer Lambda/DynamoDB/S3/SNS | ap-northeast-1 |

## 실행
```powershell
cd C:\Users\competitor\2026-terraform\02\2과제\bastion
terraform init; terraform apply -auto-approve
terraform output -raw ssm_connect_command
aws ssm start-session --target <id> --region ap-southeast-1
```
```bash
until [ -f /opt/task2/READY ]; do sleep 5; done
BIBUNHO=<비번호> bash /opt/task2/deploy.sh
```

## 배포파일 / 수동 단계
- module1: `test.csv` 를 S3 `input/` 에 업로드(채점). lambda.md/workflow.md 참고.
- module2: EC2(wsc2026-analytics-ec2) 에 배포파일 앱 배치(8080, Kinesis put). Flink Studio 노트북 SQL 은 콘솔.
- module3: SNS 이메일 구독 Confirm.
- module4: producer EC2 에서 토픽 생성(wsc2026-sensor-raw 3/2, wsc2026-sensor-alert 1/2). Application.hwp/lambda.hwp 참고.

## 비번호
- module1 S3 = `wsc2026-student-score-bucket-<비번호>`, module4 S3 = `wsc2026-sensor-alert-bucket-<비번호>`. deploy.sh 의 `BIBUNHO` 로 주입.

## 검증
module1~4 + bastion `terraform validate` 통과. Lambda 런타임 python3.14 (aws provider 6.x).

## NEEDS-REVIEW
- MSK 토픽 생성은 TF 밖(producer EC2 kafka CLI). 
- Managed Flink Studio 는 CLI(null_resource)로 생성 — apply 머신(bastion)에 aws CLI 필요(설치됨).
- module3 EventBridge eventName 매핑은 CloudTrail 관리이벤트 기반(타입변경=ModifyInstanceAttribute, Role변경=Associate/ReplaceIamInstanceProfile). 채점 스크립트의 정확한 eventName 과 대조 권장.


---

## 🧹 Bastion 네트워크 & 삭제

- **Bastion 네트워크**: 전용 VPC `10.250.0.0/16` + 퍼블릭 서브넷 `10.250.0.0/24` + IGW.
  (이 대회 계정엔 **default VPC 가 없어** bastion 이 자체 VPC 를 생성한다. 접속은 SSM 아웃바운드 443만 사용.)
- **AMI**: 표준 AL2023(`al2023-ami-2023.*`)만 선택 — minimal AMI 는 SSM 에이전트가 없어 제외.
- **Bastion 삭제** (채점 대상과 분리된 별도 state → bastion 만 안전하게 제거):
```powershell
cd C:\Users\competitor\2026-terraform\02\2과제\bastion
terraform destroy -auto-approve
```
> 채점 대상(main/모듈)은 bastion 안에서 별도로 destroy. EKS 가 private-only 인 과제는 destroy 전 public 재오픈 필요.
