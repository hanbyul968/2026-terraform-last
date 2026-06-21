#!/bin/bash
set -e

REGION="ap-southeast-2"
CLUSTER="wsc2026-logging-cluster"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name $CLUSTER --region $REGION

echo "=== Fix StorageClass ==="
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

echo "=== Installing Helm ==="
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "=== Adding Helm repos ==="
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

echo "=== Installing ALB Controller ==="
VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
ALB_ROLE_ARN=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role --query "Role.Arn" --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_ARN \
  --set vpcId=$VPC_ID \
  --wait --timeout 5m

echo "=== Creating logging namespace ==="
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

echo "=== Installing Loki ==="
helm upgrade --install loki grafana/loki -n logging \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=true \
  --set singleBinary.persistence.size=10Gi \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.limits_config.allow_structured_metadata=true \
  --set 'loki.schemaConfig.configs[0].from=2024-01-01' \
  --set 'loki.schemaConfig.configs[0].store=tsdb' \
  --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
  --set 'loki.schemaConfig.configs[0].schema=v13' \
  --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
  --set 'loki.schemaConfig.configs[0].index.period=24h' \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --timeout 10m

echo "=== Installing Grafana ==="
helm upgrade --install grafana grafana/grafana -n logging \
  --set adminUser="admin" \
  --set adminPassword="wsc2026-logging-admin-61" \
  --set service.type=ClusterIP \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Loki' \
  --set 'datasources.datasources\.yaml.datasources[0].type=loki' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://loki:3100' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy' \
  --set 'datasources.datasources\.yaml.datasources[0].isDefault=true' \
  --wait --timeout 5m

echo "=== Installing Fluent Bit ==="
helm upgrade --install fluent-bit grafana/fluent-bit -n logging \
  --set config.outputs="[OUTPUT]\n    Name        loki\n    Match       *\n    Host        loki\n    Port        3100\n    Labels      job=fluent-bit\n    auto_kubernetes_labels on" \
  --timeout 5m 2>/dev/null || \
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      containers:
        - name: fluent-bit
          image: grafana/fluent-bit-plugin-loki:latest
          env:
            - name: LOKI_URL
              value: "http://loki:3100/loki/api/v1/push"
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlogpods
          hostPath:
            path: /var/log/pods
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: logging
EOF

echo "=== Deploying Nginx ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: logging
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
EOF

echo "=== Setting up TargetGroupBinding for Grafana ==="
GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names wsc2026-logging-grafana-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)

cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: grafana-tgb
  namespace: logging
spec:
  serviceRef:
    name: grafana
    port: 80
  targetGroupARN: ${GRAFANA_TG_ARN}
  targetType: ip
EOF

echo "=== Done! ==="
echo ""
kubectl get po -n logging
kubectl get po -A | grep fluent-bit
echo ""
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region $REGION --query "LoadBalancers[0].DNSName" --output text)
echo "Grafana URL: http://${ALB_DNS}"
echo "Grafana Login: admin / wsc2026-logging-admin-61"
