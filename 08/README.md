# Task 09

# WorldPay 인프라 구성

## 사용법

### 1. Terraform Apply (로컬 or CloudShell)
```bash
cd terraform
terraform init && terraform apply -auto-approve
```

### 2. Bastion에서 setup.sh 실행 (원커맨드)
```bash
aws s3 cp s3://$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')/setup.sh - | bash
```

## 주요 사항
- VPC Endpoints (ECR, EKS, EKS-Auth, STS, Logs, KMS, EC2, ELB, S3, DynamoDB)로 NAT 없이 동작
- Prometheus/Grafana 이미지는 Bastion에서 ECR 미러링 후 설치
- CloudFront VPC Origin으로 internal ALB 접근
- Dockerfile: multi-stage (scratch + ca-certificates) → 3.51MB
