# 2026 전국기능경기대회 클라우드컴퓨팅 1과제 (V2) - Terraform 단일 apply

`wsc-*` 리소스를 문제지/채점기준표에 맞춰 **단일 `terraform apply`** 로 구성한다.
수동 작업 없음(eksctl/스크립트 별도 실행 불필요). Windows PowerShell 기준.

## 사전 준비
- AWS 자격증명 (ap-northeast-2, 관리자급 권한)
- `terraform` >= 1.6, `aws` CLI v2, `kubectl`, `docker` 데몬 실행 중 (PATH 등록)
- 배포파일은 `files/`(book, index.html, main.jpeg, Dockerfile, cf-function.js)에 포함됨

## 실행
```powershell
cd "01\1과제"
terraform init
terraform apply -auto-approve
```
- EKS/노드그룹/헬름까지 약 20~30분 소요.
- apply 중에는 EKS endpoint 가 public+private 로 열려 있어야 k8s/helm 리소스를 적용할 수 있고,
  맨 마지막 `null_resource.private_only` 가 **public 을 꺼서 private-only** 로 만든다(채점 요구사항).

## 채점 항목 매핑
| 채점 | 구현 파일 |
|------|-----------|
| 1 VPC/서브넷/RT/IGW/NAT/FlowLogs(KMS, 12필드) | vpc.tf, kms.tf |
| 2 S3(DSSE-KMS, SSE-C 차단, 버킷키, 비공개)+CloudFront(Function /index,/main) | s3_cloudfront.tf |
| 3 ECR book-ecr(KMS, IMMUTABLE, scanOnPush, CVE 0) | ecr.tf, files/Dockerfile |
| 4 DynamoDB wsc-dynamo(AWS관리형KMS, PITR, 삭제방지, 온디맨드)+AWS Backup(cold30/del120) | dynamodb.tf |
| 5 EKS 1.35(private, KMS, 로깅5종)+노드그룹 app/addon+book StatefulSet | eks.tf, k8s_book.tf |
| 6 ALB wsc-alb(internet-facing, 80, IP, 404 기본)+/health,/v1/* | alb.tf |
| 7 Prometheus(15s, 9090)+RuleGroup book 3 alerts | monitoring.tf |

## destroy 시 주의
private-only 로 닫혀 있어 destroy 전에 public 을 잠시 켜야 k8s/helm 리소스를 정리할 수 있다.
```powershell
aws eks update-cluster-config --region ap-northeast-2 --name wsc-eks-cluster `
  --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
# 활성화(약 수 분) 후
terraform destroy
```

## 검증 상태
- `terraform fmt` / `validate` / `plan` 통과 (Plan: 89 add, 0 change, 0 destroy, 오류 없음).
- 실제 `apply`(EKS 프로비저닝/도커 빌드/헬름)는 환경에서 직접 1회 수행하여 최종 확인 필요.
