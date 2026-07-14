#!/bin/bash
# =============================================================================
# 앱 배포 (2단계 flow 에서 누락됐던 옛 setup.sh 재구성)
#   null_resource.deploy_app 가 terraform apply 중(=bastion 안)에서 실행한다.
#   값은 terraform 이 주입한다(상단 변수). 재실행 가능하도록 || true / --overwrite 사용.
# 수행: book 이미지 빌드/푸시(2-2) → 이미지 미러 → namespace(4-4) → LBC(helm) →
#       book 배포(+IRSA/TGB/NetworkPolicy 4-5) → grafana(helm 10-2) → fluent-bit(10-1)
# =============================================================================
set -eu

ACCOUNT_ID="${account_id}"
REGION="${region}"
CLUSTER_NAME="${cluster_name}"
BOOK_TG_ARN="${book_tg_arn}"
GRAFANA_TG_ARN="${grafana_tg_arn}"
OIDC_ID="${oidc_id}"
BASEDIR="${basedir}"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

export KUBECONFIG=/tmp/gj2026.kubeconfig
export HOME="$${HOME:-/root}"

# helm 보장 (userdata 에서 get.helm.sh 타임아웃으로 설치 실패했을 수 있음)
if ! command -v helm >/dev/null 2>&1; then
  for i in 1 2 3 4 5 6; do
    curl -fsSL --connect-timeout 15 --max-time 180 \
      "https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz" -o /tmp/helm.tgz \
      && tar xzf /tmp/helm.tgz -C /tmp \
      && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
      && break
    echo "helm install retry $i..."; sleep 15
  done
fi
command -v helm >/dev/null 2>&1 || { echo "FATAL: helm 설치 실패 - 네트워크 확인 필요"; exit 1; }

echo "=== EKS kubeconfig ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG"

echo "=== ECR Login ==="
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "=== Build & Push book image (2-2: scratch 기반, 수 MB) ==="
docker build --platform linux/amd64 --provenance=false -t "$REGISTRY/book:latest" "$BASEDIR/application"
docker push "$REGISTRY/book:latest"

echo "=== Wait for >=4 nodes Ready ==="
until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 4 ]; do sleep 10; done

echo "=== Approve kubelet-serving CSRs ==="
kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{"\n"}{end}' \
  | xargs -r kubectl certificate approve || true

echo "=== Mirror grafana / fluent-bit / LBC / nginx images to ECR ==="
docker pull grafana/grafana:12.3.1
docker tag grafana/grafana:12.3.1 "$REGISTRY/grafana:12.3.1"
aws ecr create-repository --repository-name grafana --region "$REGION" 2>/dev/null || true
docker push "$REGISTRY/grafana:12.3.1"

docker pull amazon/aws-for-fluent-bit:latest
docker tag amazon/aws-for-fluent-bit:latest "$REGISTRY/aws-for-fluent-bit:latest"
aws ecr create-repository --repository-name aws-for-fluent-bit --region "$REGION" 2>/dev/null || true
docker push "$REGISTRY/aws-for-fluent-bit:latest"

docker pull public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0
docker tag public.ecr.aws/eks/aws-load-balancer-controller:v3.4.0 "$REGISTRY/aws-load-balancer-controller:v3.4.0"
aws ecr create-repository --repository-name aws-load-balancer-controller --region "$REGION" 2>/dev/null || true
docker push "$REGISTRY/aws-load-balancer-controller:v3.4.0"

# NetworkPolicy(4-5) 테스트용 nginx (pull-through cache 경로와 동일 위치로 미러)
docker pull public.ecr.aws/nginx/nginx:latest
docker tag public.ecr.aws/nginx/nginx:latest "$REGISTRY/ecr-public/nginx/nginx:latest"
aws ecr create-repository --repository-name ecr-public/nginx/nginx --region "$REGION" 2>/dev/null || true
docker push "$REGISTRY/ecr-public/nginx/nginx:latest"

echo "=== Namespaces (4-4: skills / monitoring / logging) ==="
kubectl apply -f "$BASEDIR/k8s/namespace.yaml"

echo "=== IRSA + Install AWS Load Balancer Controller ==="
cat > /tmp/lbc-trust.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller","oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:aud": "sts.amazonaws.com"}}
  }]
}
TRUSTEOF
aws iam create-role --role-name AmazonEKSLoadBalancerControllerRole --assume-role-policy-document file:///tmp/lbc-trust.json 2>/dev/null || true
# role 이 이전 클러스터에서 남아있으면 trust 가 옛 OIDC 를 가리킨다 → 현재 OIDC 로 항상 갱신
aws iam update-assume-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-document file:///tmp/lbc-trust.json
# TargetGroupBinding 으로 pod IP 등록: elasticloadbalancing + ec2:Describe* 필요
aws iam attach-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess 2>/dev/null || true
aws iam attach-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess 2>/dev/null || true
kubectl create serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null || true
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole --overwrite

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository="$REGISTRY/aws-load-balancer-controller" \
  --set image.tag=v3.4.0 \
  --set enableServiceMutatorWebhook=false
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s
# 이전 실행에서 stale IRSA 로 떠 있던 LBC pod 의 credential 캐시를 비우기 위해 재시작
kubectl -n kube-system rollout restart deployment/aws-load-balancer-controller
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

echo "=== Wait for LBC webhook to respond ==="
until [ -n "$(kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; do
  echo "waiting for webhook endpoints..."; sleep 5
done
for i in $(seq 1 24); do
  if echo '{"apiVersion":"elbv2.k8s.aws/v1beta1","kind":"TargetGroupBinding","metadata":{"name":"webhook-probe","namespace":"skills"},"spec":{"serviceRef":{"name":"x","port":80},"targetGroupARN":"arn:aws:elasticloadbalancing:ap-northeast-2:000000000000:targetgroup/x/0000000000000000","targetType":"ip"}}' \
       | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
    echo "webhook ready"; break
  fi
  echo "waiting for webhook to respond... ($i)"; sleep 5
done

echo "=== Deploy book app (IRSA + Deployment + Service) ==="
kubectl create serviceaccount book-sa -n skills 2>/dev/null || true
kubectl annotate serviceaccount book-sa -n skills \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-book-app-role --overwrite
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" "$BASEDIR/k8s/book.yaml" | kubectl apply -f -

echo "=== TargetGroupBindings (book / grafana) ==="
sed -e "s|PLACEHOLDER_BOOK_TG|$BOOK_TG_ARN|g" -e "s|PLACEHOLDER_GRAFANA_TG|$GRAFANA_TG_ARN|g" \
  "$BASEDIR/k8s/ingress.yaml" | kubectl apply -f -

echo "=== NetworkPolicy (4-5) ==="
kubectl apply -f "$BASEDIR/k8s/network-policy.yaml"

echo "=== nginx pre-puller (4-5 nginx-test 이미지 모든 노드에 미리 캐싱) ==="
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" "$BASEDIR/k8s/nginx-prepuller.yaml" | kubectl apply -f -

echo "=== Grafana (IRSA + helm) ==="
kubectl create serviceaccount grafana -n monitoring 2>/dev/null || true
kubectl annotate serviceaccount grafana -n monitoring \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/gj2026-grafana-role --overwrite
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" "$BASEDIR/k8s/grafana-values.yaml" > /tmp/grafana-values.yaml
helm upgrade --install grafana grafana/grafana -n monitoring -f /tmp/grafana-values.yaml
kubectl apply -f "$BASEDIR/k8s/grafana.yaml"

echo "=== IRSA for Fluent Bit (10-1) ==="
cat > /tmp/fb-trust.json <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:logging:fluent-bit-sa","oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:aud": "sts.amazonaws.com"}}
  }]
}
TRUSTEOF
aws iam create-role --role-name FluentBitRole --assume-role-policy-document file:///tmp/fb-trust.json 2>/dev/null || true
# role 이 이전 클러스터에서 남아있으면 trust 가 옛 OIDC 를 가리킨다 → 현재 OIDC 로 항상 갱신
aws iam update-assume-role-policy --role-name FluentBitRole --policy-document file:///tmp/fb-trust.json
aws iam attach-role-policy --role-name FluentBitRole --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess 2>/dev/null || true
kubectl create serviceaccount fluent-bit-sa -n logging 2>/dev/null || true
kubectl annotate serviceaccount fluent-bit-sa -n logging \
  eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/FluentBitRole --overwrite
sed "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" "$BASEDIR/k8s/fluentbit.yaml" | kubectl apply -f -

echo "=== Done. Pods: ==="
kubectl get pods -A || true
