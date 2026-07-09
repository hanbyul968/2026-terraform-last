# 제1과제 — 콘솔 실행 가이드 (처음부터 끝까지)

> **환경**: 로컬 Windows PowerShell + AWS Bastion EC2 (SSH)  
> **예상 소요**: 약 50~70분 (EKS 생성 30분 포함)  
> **계정 ID**: 실행 시 자동 조회됨 (`$ACCOUNT`)

---

## 목차

1. [사전 준비 (로컬)](#1-사전-준비-로컬)
2. [bootstrap apply — VPC + Bastion 생성](#2-bootstrap-apply--vpc--bastion-생성)
3. [Bastion SSH 접속](#3-bastion-ssh-접속)
4. [app apply — 나머지 AWS 리소스 생성](#4-app-apply--나머지-aws-리소스-생성)
5. [setup.sh — EKS + k8s + 이미지 미러링](#5-setupsh--eks--k8s--이미지-미러링)
6. [완료 확인](#6-완료-확인)
7. [채점 실행](#7-채점-실행)
8. [트러블슈팅](#8-트러블슈팅)

---

## 1. 사전 준비 (로컬)

> **로컬 PowerShell에서 실행**

### AWS CLI 자격증명 확인

```powershell
aws sts get-caller-identity
# Account, UserId, Arn 출력되면 OK
```

### Terraform 설치 확인

```powershell
terraform version
# Terraform v1.x.x 출력되면 OK
```

### 작업 디렉터리 이동

```powershell
cd C:\Users\competitor\2026-terraform\09\1과제
```

---

## 2. bootstrap apply — VPC + Bastion 생성

> **로컬 PowerShell에서 실행**  
> 생성 항목: VPC, 서브넷, IGW, 라우팅, VPC Endpoint, Bastion EC2, 코드 배포용 S3 버킷

```powershell
cd C:\Users\competitor\2026-terraform\09\1과제\bootstrap
terraform init
terraform apply -auto-approve
```

완료 후 출력값 저장:

```powershell
terraform output
# bastion_public_ip  = "x.x.x.x"
# ssh_command        = "ssh ec2-user@x.x.x.x"
# code_bucket        = "worldpay-code-xxxxxxxxxx"
```

> ⏳ **약 3~5분** 소요. Bastion user_data가 백그라운드에서 awscli/kubectl/eksctl/terraform 설치 중.

---

## 3. Bastion SSH 접속

> **로컬 PowerShell에서 실행**

```powershell
# terraform output에서 나온 IP 사용
ssh ec2-user@<bastion_public_ip>
# 비밀번호: worldpay2026!
```

접속 후 Bastion에서 user_data 완료 확인:

```bash
# user_data 로그 확인 (완료되면 "Setup Done" 출력)
sudo tail -f /var/log/cloud-init-output.log
# Ctrl+C 로 중단

# 또는 terraform 설치됐는지 확인
terraform version
```

> ⏳ bootstrap apply 완료 후 **1~2분** 기다렸다가 접속하면 user_data가 이미 완료됨.  
> 만약 terraform 명령을 못 찾으면 아래 수동 설치 실행:
> ```bash
> sudo yum install -y unzip
> curl -sL https://releases.hashicorp.com/terraform/1.13.4/terraform_1.13.4_linux_amd64.zip -o /tmp/tf.zip
> sudo unzip -o /tmp/tf.zip -d /usr/local/bin
> ```

---

## 4. app apply — 나머지 AWS 리소스 생성

> **Bastion bash에서 실행**  
> 생성 항목: KMS, DynamoDB, S3, ECR, ALB(book/grafana), CloudFront, IAM Role, CloudWatch Log Group, manifest S3 버킷

### 코드가 없으면 수동 다운로드

```bash
# user_data가 이미 받아뒀으면 이 단계 생략
ls ~/project/app/main.tf 2>/dev/null && echo "OK" || echo "없음"

# 없으면 수동 다운로드
BUCKET=$(cat ~/CODE_BUCKET.txt 2>/dev/null || aws s3 ls | grep worldpay-code | awk '{print $3}')
aws s3 cp s3://$BUCKET/ ~/project --recursive --region ap-northeast-2
```

### app apply 실행

```bash
cd ~/project/app
terraform init
terraform apply -auto-approve
```

> ⏳ **약 5~10분** 소요 (CloudFront 배포 생성이 가장 오래 걸림).

완료 후 확인:

```bash
terraform output
# cloudfront_domain  = "xxxxxxx.cloudfront.net"
# book_alb_dns       = "book-alb-xxx.ap-northeast-2.elb.amazonaws.com"
# grafana_alb_dns    = "grafana-alb-xxx.ap-northeast-2.elb.amazonaws.com"
```

---

## 5. setup.sh — EKS + k8s + 이미지 미러링

> **Bastion bash에서 실행**  
> 처리 항목: Docker 설치, 이미지 ECR 미러링, EKS 클러스터 생성, k8s 리소스 배포, Helm(Prometheus/Grafana), ALBC 설치, TargetGroupBinding

### manifest 파일 다운로드 후 실행

```bash
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
mkdir -p /tmp/worldpay && cd /tmp/worldpay
aws s3 cp s3://$BUCKET/ . --recursive
chmod +x setup.sh
./setup.sh 2>&1 | tee /tmp/setup.log
```

> ⏳ **약 35~45분** 소요.  
> 중간에 오류가 나도 `|| true` 처리로 대부분 계속 진행됨.  
> 완료 시 `===== Setup Complete! =====` 출력.

### 진행 상황 모니터링 (별도 터미널)

```bash
# 다른 SSH 세션을 열어서 로그 확인
tail -f /tmp/setup.log

# EKS 클러스터 상태 확인
watch -n 30 "aws eks describe-cluster --name worldpay-cluster --query 'cluster.status' --output text 2>/dev/null"
```

---

## 6. 완료 확인

> **Bastion bash에서 실행**

### kubeconfig 설정 (setup.sh 이후)

```bash
aws eks update-kubeconfig --name worldpay-cluster --region ap-northeast-2
```

### Pod 상태 확인

```bash
kubectl get pods -A
# 모든 Pod가 Running 상태여야 함
```

예상 출력:
```
NAMESPACE     NAME                                       READY   STATUS    
worldpay      book-deploy-xxx                            1/1     Running   
logging       worldpay-fluentbit-xxx                     1/1     Running   
monitoring    grafana-xxx                                1/1     Running   
monitoring    prometheus-server-xxx                      1/1     Running   
kube-system   aws-load-balancer-controller-xxx           1/1     Running   
```

### ALB 타겟 상태 확인

```bash
# book 타겟
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --names book-tg --query "TargetGroups[0].TargetGroupArn" --output text) \
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State}" \
  --output table

# grafana 타겟
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --names grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text) \
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State}" \
  --output table
```

> `healthy` 상태가 되어야 API / Grafana 접근 가능.

### API 테스트

```bash
CF=$(aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text)
echo "CloudFront: https://$CF"

# 예약 생성
curl -s -X POST https://$CF/v1/book \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"C001","username":"Alice","email":"a@a.com","concert_name":"Test"}' | jq .

# 조회
curl -s https://$CF/v1/book | jq .
```

### Grafana 접속

```bash
echo "Grafana: http://$(aws elbv2 describe-load-balancers --names grafana-alb --query 'LoadBalancers[0].DNSName' --output text)"
# 브라우저에서 접속
# ID: admin / PW: worldpay2026!
```

---

## 7. 채점 실행

> **Bastion bash에서 실행**

```bash
aws configure set region ap-northeast-2
export AWS_PAGER=""
export BUCKET_NAME=worldpay-bucket-$(aws sts get-caller-identity --query Account --output text)

# mark.sh 위치 확인 후 실행
ls /tmp/worldpay/mark_v3.sh && bash /tmp/worldpay/mark_v3.sh
# 또는
ls ~/mark.sh && bash ~/mark.sh
```

---

## 8. 트러블슈팅

### ❌ Docker "no space left on device"

**증상**: setup.sh 실행 중 이미지 pull/push 시 `no space left on device` 오류

```bash
# 원인 확인
df -h /

# 해결: Docker 캐시 전체 정리
sudo docker system prune -af --volumes

# 정리 후 여유 공간 재확인
df -h /

# setup.sh 재실행
cd /tmp/worldpay && ./setup.sh 2>&1 | tee /tmp/setup.log
```

---

### ❌ eksctl "AlreadyExistsException: Stack already exists"

**증상**: `creating CloudFormation stack "eksctl-worldpay-cluster-cluster": AlreadyExistsException`  
**원인**: 이전 실행에서 CloudFormation 스택이 생성됐으나 클러스터가 완성되지 않음

```bash
# 1. 실패한 CF 스택 상태 확인
aws cloudformation describe-stacks \
  --stack-name eksctl-worldpay-cluster-cluster \
  --query 'Stacks[0].StackStatus' --output text

# 2. 스택 삭제 (ROLLBACK_COMPLETE 또는 CREATE_FAILED 상태일 때)
aws cloudformation delete-stack --stack-name eksctl-worldpay-cluster-cluster
aws cloudformation wait stack-delete-complete --stack-name eksctl-worldpay-cluster-cluster
echo "스택 삭제 완료"

# 3. setup.sh 재실행
cd /tmp/worldpay && ./setup.sh 2>&1 | tee /tmp/setup.log
```

> 스택 상태가 `DELETE_IN_PROGRESS` 이면 wait 명령으로 완료까지 대기합니다 (최대 10분).

---

### ❌ kubectl "connection refused" / kubeconfig 미설정

**증상**: `The connection to the server localhost:8080 was refused`

```bash
# 원인 확인: kubeconfig가 없거나 잘못됨
cat ~/.kube/config 2>/dev/null | head -5

# 해결: kubeconfig 재설정
aws eks update-kubeconfig --name worldpay-cluster --region ap-northeast-2

# 확인
kubectl get nodes
```

---

### ❌ helm "Kubernetes cluster unreachable"

**증상**: `Error: Kubernetes cluster unreachable`

kubeconfig 미설정이 원인입니다. 위의 kubeconfig 재설정 후 helm 명령을 재실행:

```bash
aws eks update-kubeconfig --name worldpay-cluster --region ap-northeast-2

# ALBC 설치
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=worldpay-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=$ECR/aws-load-balancer-controller \
  --set image.tag=v2.13.3 \
  --wait --timeout 300s

# Prometheus
helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace \
  -f /tmp/worldpay/prometheus-values.yaml \
  --set server.image.repository=$ECR/prometheus \
  --set server.image.tag=v3.12.0 \
  --set configmapReload.prometheus.image.repository=$ECR/prometheus-config-reloader \
  --set configmapReload.prometheus.image.tag=v0.91.0 \
  --set kube-state-metrics.image.registry=$ECR \
  --set kube-state-metrics.image.repository=kube-state-metrics \
  --set kube-state-metrics.image.tag=v2.19.0 \
  --set nodeExporter.image.registry=$ECR \
  --set nodeExporter.image.repository=node-exporter \
  --set nodeExporter.image.tag=v1.11.1 \
  --wait --timeout 300s

# Grafana
helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f /tmp/worldpay/grafana-values.yaml \
  --set image.registry=$ECR \
  --set image.repository=grafana \
  --set image.tag=12.3.1 \
  --set downloadDashboardsImage.registry=$ECR \
  --set downloadDashboardsImage.repository=curl \
  --set downloadDashboardsImage.tag=8.9.1 \
  --set initChownData.image.registry=$ECR \
  --set initChownData.image.repository=curl \
  --set initChownData.image.tag=8.9.1 \
  --set testFramework.image.registry=$ECR \
  --set testFramework.image.repository=curl \
  --set testFramework.image.tag=8.9.1 \
  --set service.type=ClusterIP \
  --set serviceAccount.create=true \
  --set serviceAccount.name=grafana \
  --wait --timeout 300s
```

---

### ❌ EKS 노드그룹이 없어서 노드가 없음

**증상**: `kubectl get nodes` 결과가 없거나 NotReady

```bash
# 노드그룹 상태 확인
aws eks describe-nodegroup \
  --cluster-name worldpay-cluster \
  --nodegroup-name worldpay-nodegroup \
  --query 'nodegroup.status' --output text

# 없으면 생성
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-a --query "Subnets[0].SubnetId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-c --query "Subnets[0].SubnetId" --output text)

aws iam create-role --role-name worldpay-nodegroup-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true
aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy 2>/dev/null || true
aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy 2>/dev/null || true
aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>/dev/null || true

aws eks create-nodegroup --cluster-name worldpay-cluster \
  --nodegroup-name worldpay-nodegroup \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --instance-types t3.large \
  --subnets $SUBNET_A $SUBNET_C \
  --node-role arn:aws:iam::${ACCOUNT}:role/worldpay-nodegroup-role

echo "노드그룹 ACTIVE 대기 중..."
aws eks wait nodegroup-active --cluster-name worldpay-cluster --nodegroup-name worldpay-nodegroup
echo "노드그룹 준비 완료"
```

---

### ❌ FluentBit ImagePullBackOff / ErrImagePull

**증상**: `kubectl get pods -n logging` 에서 fluentbit pod가 `ErrImagePull`

```bash
# 이미지가 ECR에 있는지 확인
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws ecr describe-images --repository-name aws-for-fluent-bit --region ap-northeast-2 2>/dev/null \
  || echo "ECR 이미지 없음"

# 없으면 미러링 (디스크 여유 확인 후)
df -h /
ECR=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
aws ecr create-repository --repository-name aws-for-fluent-bit 2>/dev/null || true
aws ecr get-login-password --region ap-northeast-2 | sudo docker login --username AWS --password-stdin $ECR
sudo docker pull public.ecr.aws/aws-observability/aws-for-fluent-bit:latest
sudo docker tag public.ecr.aws/aws-observability/aws-for-fluent-bit:latest $ECR/aws-for-fluent-bit:latest
sudo docker push $ECR/aws-for-fluent-bit:latest

# fluentbit 재배포
cd /tmp/worldpay
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" fluentbit.yaml
kubectl apply -f fluentbit.yaml
kubectl rollout restart daemonset worldpay-fluentbit -n logging
```

---

### ❌ Grafana ALB 502 Bad Gateway (타겟 stale)

**증상**: Grafana UI 접속 시 502 / ALB 타겟이 unhealthy  
**원인**: Grafana Pod가 재시작되면서 IP가 바뀌었지만 ALB 타겟이 이전 IP를 바라봄  
**해결**: TargetGroupBinding (ALBC가 자동 관리)

```bash
# ALBC 동작 확인
kubectl get pods -n kube-system | grep aws-load-balancer

# TargetGroupBinding 상태 확인
kubectl get targetgroupbinding -A

# TGB가 없으면 수동 적용
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
cd /tmp/worldpay
BOOK_TG_ARN=$(aws elbv2 describe-target-groups --names book-tg --query "TargetGroups[0].TargetGroupArn" --output text)
GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
sed -i "s|BOOK_TG_ARN|$BOOK_TG_ARN|g; s|GRAFANA_TG_ARN|$GRAFANA_TG_ARN|g" targetgroupbinding.yaml
kubectl apply -f targetgroupbinding.yaml

# 타겟 healthy 될 때까지 대기 (약 30초~2분)
watch -n 10 "aws elbv2 describe-target-health \
  --target-group-arn $GRAFANA_TG_ARN \
  --query 'TargetHealthDescriptions[*].TargetHealth.State' --output text"
```

---

### ❌ 채점 스크립트 9-3 실패 (pod_ip 없음 / labels 과다)

FluentBit가 `Use_Kubelet On` 설정으로 되어 있어야 합니다.

```bash
# fluentbit ConfigMap 확인
kubectl get configmap fluentbit-config -n logging -o yaml | grep -A3 "Use_Kubelet"
# Use_Kubelet           On 이 있어야 함

# 없으면 재적용
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
cd /tmp/worldpay
aws s3 cp s3://$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')/ . --recursive
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" fluentbit.yaml
kubectl apply -f fluentbit.yaml
kubectl rollout restart daemonset worldpay-fluentbit -n logging
kubectl rollout status daemonset/worldpay-fluentbit -n logging --timeout=120s

# 로그 확인 (pod_ip 필드 있는지)
sleep 30
aws logs filter-log-events \
  --log-group-name /worldpay/application \
  --limit 1 \
  --query 'events[0].message' --output text | jq '.kubernetes'
```

---

### ❌ setup.sh 중간 실패 후 재실행

setup.sh는 대부분 `2>/dev/null || true` 로 처리되어 **전체 재실행이 안전**합니다.

```bash
# Docker 정리 후 재실행
sudo docker system prune -af --volumes
cd /tmp/worldpay
./setup.sh 2>&1 | tee /tmp/setup.log
```

단, **NAT 라우트 삭제(마지막 단계)** 는 이미 삭제됐으면 오류가 나지만 `|| true` 로 무시됩니다.

---

## 빠른 재확인 명령 모음

```bash
# 전체 Pod 상태 한 번에
kubectl get pods -A -o wide

# ALB 타겟 헬스 한 번에
for tg in book-tg grafana-tg; do
  echo "=== $tg ==="
  aws elbv2 describe-target-health \
    --target-group-arn $(aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text) \
    --query "TargetHealthDescriptions[*].{IP:Target.Id,State:TargetHealth.State}" \
    --output table
done

# CloudFront 도메인
aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text

# Grafana URL
echo "http://$(aws elbv2 describe-load-balancers --names grafana-alb --query 'LoadBalancers[0].DNSName' --output text)"

# 최신 CloudWatch 로그 (9-3 채점 확인)
aws logs filter-log-events \
  --log-group-name /worldpay/application \
  --limit 3 \
  --query 'events[*].message' --output text | python3 -c "
import sys,json
for line in sys.stdin:
    try: print(json.dumps(json.loads(line.strip()), indent=2, ensure_ascii=False))
    except: pass
"
```
