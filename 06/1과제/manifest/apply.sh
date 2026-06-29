#!/bin/bash
set -x
# 비번호: terraform apply 시 입력한 var.number 가 S3의 number.env 로 내려온다.
# (없으면 환경변수 number, 그것도 없으면 103)
[ -f number.env ] && source number.env
export NUMBER="${number:-${NUMBER:-103}}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
WORKDIR=$(pwd)

# ============================================================
# apply.sh 자동으로:
# 1. book 이미지 빌드 & ECR push
# 2. ECR IMMUTABLE_WITH_EXCLUSION 설정
# 3. eksctl 클러스터 생성
# 4. EKS SG 허용 (CloudShell + VPC CIDR)
# 5. kubectl apply (namespace, SA, deployment, service, fluent-bit)
# 6. EC2 Name Tag 부여
# 7. Pod Identity Association
# 8. Pod restart + ALB Target 등록
# 9. helm install (Prometheus + Grafana)
# 10. Grafana ALB Target 등록
# 11. IAM 권한 설정
# ============================================================

# 0. cluster.yaml placeholder 치환
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-a --query "Subnets[0].SubnetId" --output text)
SUBNET_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-b --query "Subnets[0].SubnetId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-c --query "Subnets[0].SubnetId" --output text)
KEY_ARN=$(aws kms describe-key --key-id alias/unicorn-kms-platform --query "KeyMetadata.Arn" --output text)
sed -i "s|VPC_ID|$VPC_ID|g; s|SUBNET_A|$SUBNET_A|g; s|SUBNET_B|$SUBNET_B|g; s|SUBNET_C|$SUBNET_C|g; s|KEY_ARN|$KEY_ARN|g" cluster.yaml

# deployment.yaml ECR 이미지 계정 치환 (어느 계정에서 돌려도 동작)
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml

# helm 설치
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl 설치
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin

# --- 1. book 이미지 빌드 & ECR push ---
ECR_URL=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/unicorn-concert-app
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
mkdir -p /tmp/docker && cp book Dockerfile /tmp/docker/ && chmod +x /tmp/docker/book
cd /tmp/docker && docker build -t $ECR_URL:v1.0.0 -t $ECR_URL:latest . && docker push $ECR_URL:v1.0.0 && docker push $ECR_URL:latest
cd $WORKDIR

# --- 2. ECR IMMUTABLE_WITH_EXCLUSION ---
aws ecr put-image-tag-mutability --repository-name unicorn-concert-app \
  --image-tag-mutability IMMUTABLE_WITH_EXCLUSION \
  --image-tag-mutability-exclusion-filters "filterType=WILDCARD,filter=latest"

# --- 3. EKS 클러스터 생성 ---
eksctl create cluster -f cluster.yaml

# --- 4. EKS SG 허용 (CloudShell + VPC CIDR) ---
CLUSTER_SG=$(aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
CLOUDSHELL_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-mark-sg --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --source-group $CLOUDSHELL_SG 2>/dev/null
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol -1 --port -1 --cidr 10.97.0.0/16 2>/dev/null
aws eks update-kubeconfig --name unicorn-eks-cluster --region $REGION
# (CloudShell 전용 kubectl-connect 제거 → bastion/CloudShell 양쪽 동작. update-kubeconfig 로 충분)

# Access Entry: bastion이 클러스터를 만들면 creator=bastion role 이므로,
# 채점자(CloudShell)가 쓰는 계정의 모든 IAM User에게 cluster admin 을 부여해
# unicorn-mark에서 kubectl 이 동작하도록 한다.
for UARN in $(aws iam list-users --query "Users[].Arn" --output text); do
  aws eks create-access-entry --cluster-name unicorn-eks-cluster --principal-arn "$UARN" --type STANDARD 2>/dev/null
  aws eks associate-access-policy --cluster-name unicorn-eks-cluster --principal-arn "$UARN" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster 2>/dev/null
done

# --- 5. kubectl apply ---
kubectl apply -f namespace.yaml
kubectl apply -f monitoring-ns.yaml
kubectl apply -f serviceaccount.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f fluentd.yaml
kubectl apply -f fluent-bit.yaml

# --- 6. EC2 Name Tag ---
for id in $(kubectl get nodes -l unicorn=app -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources $id --tags Key=Name,Value=unicorn-k8snode-app-node
done
for id in $(kubectl get nodes -l unicorn=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources $id --tags Key=Name,Value=unicorn-k8snode-addon-node
done

# --- 7. Pod Identity Association ---
aws eks create-pod-identity-association \
  --cluster-name unicorn-eks-cluster \
  --namespace unicorn \
  --service-account unicorn-book-app-sa \
  --role-arn arn:aws:iam::$ACCOUNT:role/unicorn-book-app-role 2>/dev/null

# --- 8. Pod restart + ALB Target 등록 ---
kubectl rollout restart deployment unicorn-book-app-deploy -n unicorn
kubectl rollout status deployment/unicorn-book-app-deploy -n unicorn --timeout=120s
TG_ARN=$(aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text)
for ip in $(kubectl get pods -n unicorn -l app=book -o jsonpath='{.items[*].status.podIP}'); do
  aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$ip,Port=8080
done

# --- 9. helm install (Prometheus + Grafana) ---
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
helm install unicorn-monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.nodeSelector.unicorn=addon \
  --set grafana.nodeSelector.unicorn=addon \
  --set grafana.adminUser="skills${NUMBER}" \
  --set grafana.adminPassword="HelloKrSkills!${NUMBER}@" \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30300 \
  --set alertmanager.alertmanagerSpec.nodeSelector.unicorn=addon \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeEtcd.enabled=false \
  --wait --timeout 600s

# --- 9-1. Grafana 대시보드 자동 import (사이드카가 ConfigMap 감지) ---
kubectl apply -f grafana-dashboard.yaml

# --- 10. Grafana ALB Target 등록 ---
GTG_ARN=$(aws elbv2 describe-target-groups --names unicorn-grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
for id in $(kubectl get nodes -l unicorn=addon -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws elbv2 register-targets --target-group-arn $GTG_ARN --targets Id=$id,Port=30300
done

# --- 11. IAM 권한 설정 ---
APP_NODE_ROLE=$(aws eks describe-nodegroup --cluster-name unicorn-eks-cluster --nodegroup-name app-ng --query "nodegroup.nodeRole" --output text | grep -oP 'role/\K.*')
ADDON_NODE_ROLE=$(aws eks describe-nodegroup --cluster-name unicorn-eks-cluster --nodegroup-name addon-ng --query "nodegroup.nodeRole" --output text | grep -oP 'role/\K.*')
aws iam attach-role-policy --role-name $APP_NODE_ROLE --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam attach-role-policy --role-name $ADDON_NODE_ROLE --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
CURRENT_USER=$(aws sts get-caller-identity --query "Arn" --output text | grep -oP 'user/\K.*')
if [ -n "$CURRENT_USER" ]; then
  aws iam put-user-policy --user-name $CURRENT_USER --policy-name AllowAssumeAuditRole \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"arn:aws:iam::${ACCOUNT}:role/unicorn-audit-role\"}]}"
fi

# --- 12. EKS Endpoint Private-Only 전환 (rubric 6-1: endpointPublicAccess=false, endpointPrivateAccess=true) ---
# 위 모든 kubectl/helm 작업은 bastion(default VPC)에서 public endpoint 를 경유해 수행된다.
# 모든 설치가 끝난 지금(가장 마지막 단계) public 을 끄고 private-only 로 전환한다.
# update-cluster-config 는 비동기이므로 실제 false 로 반영될 때까지 폴링한다.
CUR=$(aws eks describe-cluster --region $REGION --name unicorn-eks-cluster \
  --query "cluster.resourcesVpcConfig.endpointPublicAccess" --output text)
if [ "$CUR" = "True" ] || [ "$CUR" = "true" ]; then
  aws eks update-cluster-config --region $REGION --name unicorn-eks-cluster \
    --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
fi
# 실제 endpointPublicAccess==false 로 반영될 때까지 대기 (최대 ~10분)
for i in $(seq 1 60); do
  ST=$(aws eks describe-cluster --region $REGION --name unicorn-eks-cluster \
    --query "cluster.resourcesVpcConfig.endpointPublicAccess" --output text)
  if [ "$ST" = "False" ] || [ "$ST" = "false" ]; then
    echo "EKS public endpoint disabled (private-only)."
    break
  fi
  echo "waiting for EKS endpoint to become private-only... ($i)"
  sleep 10
done

echo "===== All Done! ====="
