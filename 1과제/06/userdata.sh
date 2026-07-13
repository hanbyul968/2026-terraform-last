#!/bin/bash
set -e

yum install -y docker git jq
systemctl enable docker && systemctl start docker
usermod -aG docker ec2-user

curl -LO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

aws s3 cp s3://gj2026-setup-${account_id}/application/ /home/ec2-user/application/ --recursive --region ${region}
aws s3 cp s3://gj2026-setup-${account_id}/k8s/ /home/ec2-user/k8s/ --recursive --region ${region}
chown -R ec2-user:ec2-user /home/ec2-user/application /home/ec2-user/k8s

cat > /home/ec2-user/setup.sh <<'SETUPEOF'
#!/bin/bash
set -e
ACCOUNT_ID="PLACEHOLDER_ACCOUNT_ID"
REGION="PLACEHOLDER_REGION"
CLUSTER_NAME="PLACEHOLDER_CLUSTER"
BOOK_TG_ARN="PLACEHOLDER_BOOK_TG"
GRAFANA_TG_ARN="PLACEHOLDER_GRAFANA_TG"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "=== EKS kubeconfig ==="
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

echo "=== ECR Login ==="
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

echo "=== Build & Push book image ==="
cd /home/ec2-user/application
docker build -t $REGISTRY/book:latest .
docker push $REGISTRY/book:latest
cd /home/ec2-user

echo "=== Wait for nodes ==="
echo "Waiting for nodes to be Ready..."
until [ $(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready") -ge 4 ]; do sleep 10; done
echo "All nodes ready"

echo "=== Approve kubelet serving CSRs ==="
kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{"\n"}{end}' | xargs -r kubectl certificate approve

echo "=== Pull & Push grafana image ==="
docker pull grafana/grafana:12.3.1
docker tag grafana/grafana:12.3.1 $REGISTRY/grafana:12.3.1
aws ecr create-repository --repository-name grafana --region $REGION 2>/dev/null || true
docker push $REGISTRY/grafana:12.3.1

echo "=== Pull & Push fluent-bit image ==="
docker pull amazon/aws-for-fluent-bit:latest
docker tag amazon/aws-for-fluent-bit:latest $REGISTRY/aws-for-fluent-bit:latest
aws ecr create-repository --repository-name aws-for-fluent-bit --region $REGION 2>/dev/null || true
docker push $REGISTRY/aws-for-fluent-bit:latest

echo "=== Pull & Push LBC image ==="
docker pull public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0
docker tag public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0 $REGISTRY/aws-load-balancer-controller:v3.4.0
aws ecr create-repository --repository-name aws-load-balancer-controller --region $REGION 2>/dev/null || true
docker push $REGISTRY/aws-load-balancer-controller:v3.4.0

echo "=== Pull & Push nginx image (for NetworkPolicy test) ==="
docker pull public.ecr.aws/nginx/nginx:latest
docker tag public.ecr.aws/nginx/nginx:latest $REGISTRY/ecr-public/nginx/nginx:latest
aws ecr create-repository --repository-name ecr-public/nginx/nginx --region $REGION 2>/dev/null || true
docker push $REGISTRY/ecr-public/nginx/nginx:latest

echo "=== Apply namespaces ==="
kubectl apply -f /home/ec2-user/k8s/namespace.yaml

echo "=== IRSA for LBC ==="
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text --region $REGION | cut -d/ -f5)
cat > /tmp/lbc-trust.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::PLACEHOLDER_ACCOUNT_ID:oidc-provider/oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller","oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC:aud": "sts.amazonaws.com"}}
  }]
}
TRUSTEOF
sed -i "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g; s|PLACEHOLDER_REGION|$REGION|g; s|PLACEHOLDER_OIDC|$OIDC_ID|g" /tmp/lbc-trust.json
aws iam create-role --role-name AmazonEKSLoadBalancerControllerRole --assume-role-policy-document file:///tmp/lbc-trust.json 2>/dev/null || true
aws iam attach-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess 2>/dev/null || true
kubectl create serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null || true
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole --overwrite

echo "=== Install AWS Load Balancer Controller ==="
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=$REGISTRY/aws-load-balancer-controller \
  --set image.tag=v3.4.0 \
  --set enableServiceMutatorWebhook=false

echo "=== Wait for LBC ==="
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

echo "=== Wait for LBC webhook endpoints ==="
# rollout 완료 후에도 webhook 서비스 endpoint(9443) 등록 + 컨트롤플레인 도달까지
# 시간이 더 걸린다. endpoint 가 채워지고 webhook 호출이 성공할 때까지 대기.
until [ -n "$(kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; do
  echo "waiting for webhook endpoints..."; sleep 5
done
# webhook 이 실제로 응답할 때까지 dry-run 으로 검증 (최대 ~2분)
for i in $(seq 1 24); do
  if echo '{"apiVersion":"elbv2.k8s.aws/v1beta1","kind":"TargetGroupBinding","metadata":{"name":"webhook-probe","namespace":"skills"},"spec":{"serviceRef":{"name":"x","port":80},"targetGroupARN":"arn:aws:elasticloadbalancing:ap-northeast-2:000000000000:targetgroup/x/0000000000000000","targetType":"ip"}}' \
       | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
    echo "webhook ready"; break
  fi
  echo "waiting for webhook to respond... ($i)"; sleep 5
done

echo "=== Deploy book app ==="
kubectl create serviceaccount book-sa -n skills 2>/dev/null || true
kubectl annotate serviceaccount book-sa -n skills eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-book-app-role --overwrite
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" /home/ec2-user/k8s/book.yaml | kubectl apply -f -

echo "=== Deploy TargetGroupBindings ==="
sed -e "s|PLACEHOLDER_BOOK_TG|$BOOK_TG_ARN|g" -e "s|PLACEHOLDER_GRAFANA_TG|$GRAFANA_TG_ARN|g" /home/ec2-user/k8s/ingress.yaml | kubectl apply -f -

echo "=== Deploy NetworkPolicy ==="
kubectl apply -f /home/ec2-user/k8s/network-policy.yaml

echo "=== Grafana ServiceAccount (IRSA) ==="
kubectl create serviceaccount grafana -n monitoring 2>/dev/null || true
kubectl annotate serviceaccount grafana -n monitoring eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-grafana-role --overwrite

echo "=== Install Grafana ==="
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" /home/ec2-user/k8s/grafana-values.yaml > /tmp/grafana-values.yaml
helm upgrade --install grafana grafana/grafana -n monitoring -f /tmp/grafana-values.yaml
kubectl apply -f /home/ec2-user/k8s/grafana.yaml

echo "=== IRSA for Fluent Bit ==="
cat > /tmp/fb-trust.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::PLACEHOLDER_ACCOUNT_ID:oidc-provider/oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC:sub": "system:serviceaccount:logging:fluent-bit-sa","oidc.eks.PLACEHOLDER_REGION.amazonaws.com/id/PLACEHOLDER_OIDC:aud": "sts.amazonaws.com"}}
  }]
}
TRUSTEOF
sed -i "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g; s|PLACEHOLDER_REGION|$REGION|g; s|PLACEHOLDER_OIDC|$OIDC_ID|g" /tmp/fb-trust.json
aws iam create-role --role-name FluentBitRole --assume-role-policy-document file:///tmp/fb-trust.json 2>/dev/null || true
aws iam attach-role-policy --role-name FluentBitRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess 2>/dev/null || true
kubectl create serviceaccount fluent-bit-sa -n logging 2>/dev/null || true
kubectl annotate serviceaccount fluent-bit-sa -n logging eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/FluentBitRole --overwrite

echo "=== Deploy Fluent Bit ==="
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" /home/ec2-user/k8s/fluentbit.yaml | kubectl apply -f -

echo "=== Done! ==="
kubectl get pods -A
SETUPEOF

# Replace placeholders with actual values (only in variable assignment lines)
sed -i '/^ACCOUNT_ID=/s|PLACEHOLDER_ACCOUNT_ID|${account_id}|' /home/ec2-user/setup.sh
sed -i '/^REGION=/s|PLACEHOLDER_REGION|${region}|' /home/ec2-user/setup.sh
sed -i '/^CLUSTER_NAME=/s|PLACEHOLDER_CLUSTER|${cluster_name}|' /home/ec2-user/setup.sh
sed -i '/^BOOK_TG_ARN=/s|PLACEHOLDER_BOOK_TG|${book_tg_arn}|' /home/ec2-user/setup.sh
sed -i '/^GRAFANA_TG_ARN=/s|PLACEHOLDER_GRAFANA_TG|${grafana_tg_arn}|' /home/ec2-user/setup.sh

chmod +x /home/ec2-user/setup.sh
chown ec2-user:ec2-user /home/ec2-user/setup.sh
