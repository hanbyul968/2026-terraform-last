#!/bin/bash
set -e

REGION="ap-northeast-1"
CLUSTER="o11y-cluster"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/o11y-log-generator"
S3_BUCKET="o11y-setup-${ACCOUNT_ID}"
number=${number:-00}

echo "=== Downloading files from S3 ==="
aws s3 cp s3://${S3_BUCKET}/app.py /tmp/app.py --region $REGION
aws s3 cp s3://${S3_BUCKET}/Dockerfile /tmp/Dockerfile --region $REGION

echo "=== Building and pushing Docker image ==="
aws ecr create-repository --repository-name o11y-log-generator --region $REGION 2>/dev/null || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
cd /tmp
docker build -t ${ECR_REPO}:latest .
docker push ${ECR_REPO}:latest

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name $CLUSTER --region $REGION

echo "=== Fix StorageClass ==="
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

echo "=== Installing Helm charts ==="
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# ALB Controller
VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
ALB_ROLE_ARN=$(aws iam get-role --role-name o11y-alb-controller-role --query "Role.Arn" --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE_ARN \
  --set vpcId=$VPC_ID \
  --wait --timeout 5m

# Loki (OTLP HTTP 인제스션 활성화)
helm upgrade --install o11y-loki grafana/loki -n monitoring --create-namespace \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=true \
  --set singleBinary.persistence.size=10Gi \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.limits_config.allow_structured_metadata=true \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[0].action=index_label' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[0].attributes[0]=k8s.namespace.name' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[1].action=index_label' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[1].attributes[0]=k8s.pod.name' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[2].action=index_label' \
  --set 'loki.limits_config.otlp_config.resource_attributes.attributes_config[2].attributes[0]=k8s.container.name' \
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

# Grafana
helm upgrade --install o11y-grafana grafana/grafana -n monitoring --create-namespace \
  --set adminUser="skills${number}" \
  --set adminPassword="GoodJob!Skills${number}^^" \
  --set service.type=ClusterIP \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Loki' \
  --set 'datasources.datasources\.yaml.datasources[0].type=loki' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://o11y-loki:3100' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy' \
  --set 'datasources.datasources\.yaml.datasources[0].isDefault=true' \
  --wait --timeout 5m

echo "=== Creating namespaces ==="
kubectl create namespace o11y --dry-run=client -o yaml | kubectl apply -f -

echo "=== Deploying log-generator app ==="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
  namespace: o11y
spec:
  replicas: 2
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
    spec:
      containers:
        - name: log-generator
          image: ${ECR_REPO}:latest
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: log-generator
  namespace: o11y
spec:
  selector:
    app: log-generator
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
EOF

echo "=== Deploying TargetGroupBindings ==="
APP_TG_ARN=$(aws elbv2 describe-target-groups --names o11y-app-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)
GRAFANA_TG_ARN=$(aws elbv2 describe-target-groups --names o11y-grafana-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)

cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: o11y-app-tgb
  namespace: o11y
spec:
  serviceRef:
    name: log-generator
    port: 8080
  targetGroupARN: ${APP_TG_ARN}
  targetType: ip
---
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: o11y-grafana-tgb
  namespace: monitoring
spec:
  serviceRef:
    name: o11y-grafana
    port: 80
  targetGroupARN: ${GRAFANA_TG_ARN}
  targetType: ip
EOF

echo "=== Deploying OTel Collector (o11y-otel) ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: o11y-otel-sa
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: o11y-otel-role
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: o11y-otel-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: o11y-otel-role
subjects:
  - kind: ServiceAccount
    name: o11y-otel-sa
    namespace: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: o11y-otel-config
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      filelog:
        include: [/var/log/pods/*/*/*.log]
        include_file_path: true
        start_at: beginning
        operators:
          - type: container
            id: container-parser
    processors:
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.container.name
            - k8s.node.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: connection
    exporters:
      otlphttp:
        endpoint: http://o11y-loki.monitoring.svc.cluster.local:3100/otlp
        tls:
          insecure: true
    service:
      pipelines:
        logs:
          receivers: [filelog]
          processors: [k8sattributes]
          exporters: [otlphttp]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: o11y-otel
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: o11y-otel
  template:
    metadata:
      labels:
        app: o11y-otel
    spec:
      serviceAccountName: o11y-otel-sa
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:latest
          args: ["--config=/etc/otel/config.yaml"]
          volumeMounts:
            - name: config
              mountPath: /etc/otel
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: o11y-otel-config
        - name: varlogpods
          hostPath:
            path: /var/log/pods
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
EOF

echo "=== Creating Grafana Dashboard ==="
sleep 30
GRAFANA_ALB=$(aws elbv2 describe-load-balancers --names o11y-grafana-alb --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${GRAFANA_ALB}/api/health")
  [ "$HTTP" = "200" ] && break
  sleep 10
done

LOKI_UID=$(curl -s -u "skills${number}:GoodJob!Skills${number}^^" "http://${GRAFANA_ALB}/api/datasources" | jq -r '.[0].uid')

# 대시보드 JSON 을 파일로 작성(인라인 -d 의 과도한 이스케이프로 깨지던 문제 회피).
# Panel: Log Count Over Time(막대그래프=timeseries drawStyle:bars) / Log Level Distribution(piechart) / Recent Logs(logs)
# 범례 legendFormat={{level}} => INFO/WARN/ERROR 같은 plain text 로 표시(대소문자 무시).
# $__range 는 Grafana 매크로이므로 \$ 로 escape.
cat > /tmp/log-overview-dashboard.json <<EOF
{"dashboard":{"title":"Log Overview","uid":"log-overview","panels":[
{"id":1,"title":"Log Count Over Time","type":"timeseries","gridPos":{"h":9,"w":14,"x":0,"y":0},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"fieldConfig":{"defaults":{"custom":{"drawStyle":"bars","fillOpacity":80,"stacking":{"mode":"normal","group":"A"}}}},"options":{"legend":{"displayMode":"list","placement":"bottom"}},"targets":[{"expr":"sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | level=~\"INFO|WARN|ERROR\" [1m]))","refId":"A","legendFormat":"{{level}}"}]},
{"id":2,"title":"Log Level Distribution","type":"piechart","gridPos":{"h":9,"w":10,"x":14,"y":0},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"options":{"legend":{"displayMode":"list","placement":"right"}},"targets":[{"expr":"sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | level=~\"INFO|WARN|ERROR\" [\$__range]))","refId":"A","legendFormat":"{{level}}"}]},
{"id":3,"title":"Recent Logs","type":"logs","gridPos":{"h":12,"w":24,"x":0,"y":9},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"targets":[{"expr":"{k8s_namespace_name=\"o11y\"} | json","refId":"A"}]}
],"schemaVersion":39,"time":{"from":"now-1h","to":"now"},"refresh":"10s"},"overwrite":true}
EOF

curl -s -X POST -H "Content-Type: application/json" \
  -u "skills${number}:GoodJob!Skills${number}^^" \
  "http://${GRAFANA_ALB}/api/dashboards/db" \
  --data-binary @/tmp/log-overview-dashboard.json

echo ""
echo "=== Done! ==="
kubectl get pods -n o11y
kubectl get pods -n monitoring
