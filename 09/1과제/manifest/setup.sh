#!/bin/bash
set -x
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
aws configure set region $REGION
aws configure set cli_pager ""
export AWS_PAGER=""
grep -q AWS_PAGER ~/.bashrc || echo 'export AWS_PAGER=""' >> ~/.bashrc
BUCKET=$(aws s3 ls | grep worldpay-manifest | awk '{print $3}')
ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

# ===== 0. S3에서 파일 다운로드 =====
mkdir -p /tmp/worldpay && cd /tmp/worldpay
aws s3 cp s3://$BUCKET/ . --recursive

# ===== 1. 도구 설치 =====
sudo yum install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin

# ===== 2. ECR Login & Book 이미지 빌드 (scratch, 5MB 이하) =====
aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $ECR
chmod +x book
aws ecr batch-delete-image --repository-name worldpay-book --image-ids imageTag=v1.0.0 2>/dev/null || true
sudo docker build --no-cache -t $ECR/worldpay-book:v1.0.0 .
sudo docker push $ECR/worldpay-book:v1.0.0

# ===== 3. 모든 이미지 ECR 미러링 =====
mirror() {
  local SRC=$1 REPO=$2 TAG=$3
  aws ecr create-repository --repository-name $REPO 2>/dev/null || true
  sudo docker pull $SRC
  sudo docker tag $SRC $ECR/$REPO:$TAG
  sudo docker push $ECR/$REPO:$TAG
}
mirror "quay.io/prometheus/prometheus:v3.12.0" "prometheus" "v3.12.0"
mirror "quay.io/prometheus-operator/prometheus-config-reloader:v0.91.0" "prometheus-config-reloader" "v0.91.0"
mirror "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.0" "kube-state-metrics" "v2.19.0"
mirror "quay.io/prometheus/node-exporter:v1.11.1" "node-exporter" "v1.11.1"
mirror "docker.io/grafana/grafana:12.3.1" "grafana" "12.3.1"
mirror "docker.io/curlimages/curl:8.9.1" "curl" "8.9.1"
mirror "public.ecr.aws/aws-observability/aws-for-fluent-bit:latest" "aws-for-fluent-bit" "latest"
mirror "public.ecr.aws/eks/aws-load-balancer-controller:v2.13.3" "aws-load-balancer-controller" "v2.13.3"

# ===== 4. cluster.yaml placeholder 치환 =====
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=worldpay-vpc --query "Vpcs[0].VpcId" --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-a --query "Subnets[0].SubnetId" --output text)
SUBNET_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=worldpay-isolated-subnet-c --query "Subnets[0].SubnetId" --output text)
sed -i "s|VPC_ID|$VPC_ID|g; s|SUBNET_A|$SUBNET_A|g; s|SUBNET_C|$SUBNET_C|g" cluster.yaml

# ===== 5. EKS 클러스터 생성 =====
eksctl create cluster -f cluster.yaml || true

# Nodegroup 없으면 생성
NG_STATUS=$(aws eks describe-nodegroup --cluster-name worldpay-cluster --nodegroup-name worldpay-nodegroup --query 'nodegroup.status' --output text 2>/dev/null)
if [ "$NG_STATUS" = "" ] || [ "$NG_STATUS" = "None" ]; then
  aws iam create-role --role-name worldpay-nodegroup-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true
  aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy 2>/dev/null || true
  aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy 2>/dev/null || true
  aws iam attach-role-policy --role-name worldpay-nodegroup-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>/dev/null || true
  aws eks create-nodegroup --cluster-name worldpay-cluster --nodegroup-name worldpay-nodegroup \
    --scaling-config minSize=2,maxSize=4,desiredSize=2 --instance-types t3.large \
    --subnets $SUBNET_A $SUBNET_C --node-role arn:aws:iam::${ACCOUNT}:role/worldpay-nodegroup-role
fi
echo "Waiting for nodegroup ACTIVE..."
aws eks wait nodegroup-active --cluster-name worldpay-cluster --nodegroup-name worldpay-nodegroup

# ===== 6. EKS SG 설정 =====
CLUSTER_SG=$(aws eks describe-cluster --name worldpay-cluster --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol tcp --port 443 --cidr 10.0.0.0/16 2>/dev/null || true
BOOK_ALB_SG=$(aws elbv2 describe-load-balancers --names book-alb --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
GRAFANA_ALB_SG=$(aws elbv2 describe-load-balancers --names grafana-alb --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol tcp --port 8080 --source-group $BOOK_ALB_SG 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $CLUSTER_SG --protocol tcp --port 3000 --source-group $GRAFANA_ALB_SG 2>/dev/null || true

# ===== 7. EKS access entry =====
BASTION_ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text | sed 's|assumed-role/\(.*\)/.*|role/\1|; s|:sts::|:iam::|')
aws eks create-access-entry --cluster-name worldpay-cluster --principal-arn $BASTION_ROLE_ARN --type STANDARD 2>/dev/null || true
aws eks associate-access-policy --cluster-name worldpay-cluster --principal-arn $BASTION_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster 2>/dev/null || true
rm -f ~/.kube/config
aws eks update-kubeconfig --name worldpay-cluster --region $REGION

# ===== 8. K8s manifests =====
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" deployment.yaml
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" grafana-values.yaml
sed -i "s|ACCOUNT_ID|$ACCOUNT|g" fluentbit.yaml
kubectl apply -f namespace.yaml
kubectl apply -f serviceaccount.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f fluentbit.yaml

# Node Name Tag
for id in $(kubectl get nodes -o jsonpath='{.items[*].spec.providerID}' | grep -oP 'i-[a-z0-9]+'); do
  aws ec2 create-tags --resources $id --tags Key=Name,Value=worldpay-node
done

# ===== 9. Pod Identity Associations =====
aws eks create-pod-identity-association --cluster-name worldpay-cluster --namespace worldpay --service-account book-sa \
  --role-arn arn:aws:iam::$ACCOUNT:role/worldpay-book-app-role 2>/dev/null || true
aws iam create-role --role-name worldpay-fluentbit-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' 2>/dev/null || true
aws iam put-role-policy --role-name worldpay-fluentbit-role --policy-name logs-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"*"}]}'
aws eks create-pod-identity-association --cluster-name worldpay-cluster --namespace logging --service-account fluentbit-sa \
  --role-arn arn:aws:iam::$ACCOUNT:role/worldpay-fluentbit-role 2>/dev/null || true
aws iam create-role --role-name worldpay-grafana-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' 2>/dev/null || true
aws iam put-role-policy --role-name worldpay-grafana-role --policy-name cw-policy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:*","cloudwatch:*"],"Resource":"*"}]}'
aws eks create-pod-identity-association --cluster-name worldpay-cluster --namespace monitoring --service-account grafana \
  --role-arn arn:aws:iam::$ACCOUNT:role/worldpay-grafana-role 2>/dev/null || true

# ===== ALBC 설치 =====
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=worldpay-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=$ECR/aws-load-balancer-controller \
  --set image.tag=v2.13.3 \
  --wait --timeout 300s
aws eks create-pod-identity-association --cluster-name worldpay-cluster \
  --namespace kube-system --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::$ACCOUNT:role/worldpay-albc-role 2>/dev/null || true
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# ===== 10. Pod restart (Pod Identity 적용) =====
kubectl rollout restart deployment book-deploy -n worldpay
kubectl rollout restart daemonset worldpay-fluentbit -n logging
kubectl rollout status deployment/book-deploy -n worldpay --timeout=300s

# ===== 11. TargetGroupBinding 적용 (ALBC가 타겟 자동 관리) =====
kubectl wait --for=condition=Ready pod -l app=book -n worldpay --timeout=300s
BOOK_TG_ARN=$(aws elbv2 describe-target-groups --names book-tg --query "TargetGroups[0].TargetGroupArn" --output text)
GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)
sed -i "s|BOOK_TG_ARN|$BOOK_TG_ARN|g; s|GRAFANA_TG_ARN|$GRAFANA_TG_ARN|g" targetgroupbinding.yaml
kubectl apply -f targetgroupbinding.yaml

# ===== 12. Helm - Prometheus (ECR 이미지) =====
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring --create-namespace \
  -f prometheus-values.yaml \
  --set kube-state-metrics.enabled=true \
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

# ===== 13. Helm - Grafana (ECR 이미지) =====
helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f grafana-values.yaml \
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

# Grafana Pod Identity 적용
kubectl rollout restart deployment grafana -n monitoring
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s

# ===== 15. S3 정적 파일 업로드 =====
HOSTING_BUCKET=worldpay-bucket-$ACCOUNT
aws s3 cp index.html s3://$HOSTING_BUCKET/index.html
aws s3 cp main.jpeg s3://$HOSTING_BUCKET/main.jpeg

# ===== 16. 채점 준비 — isolated subnet NAT 라우트 삭제 =====
for s in worldpay-isolated-subnet-a worldpay-isolated-subnet-c; do
  SID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$s --query 'Subnets[0].SubnetId' --output text)
  RT=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$SID --query 'RouteTables[0].RouteTableId' --output text)
  aws ec2 delete-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 2>/dev/null || true
done

echo "===== Setup Complete! ====="
echo "CloudFront: $(aws cloudfront list-distributions --query 'DistributionList.Items[0].DomainName' --output text)"
echo "Grafana: http://$(aws elbv2 describe-load-balancers --names grafana-alb --query 'LoadBalancers[0].DNSName' --output text)"
