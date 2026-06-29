#!/bin/bash
# =============================================================================
# Module 3 setup — 배포 Bastion(admin, kubectl/helm) 에서 실행.
#   - EKS(wsc-logging-cluster) 에 Loki(SingleBinary, PVC 10Gi, NLB:3100) /
#     Grafana(NLB, Loki datasource, 대시보드 'WSC2026 Container Logs' 4패널) 배포
#   - Loki NLB DNS 를 SSM(/wsc/module3/loki-endpoint) 에 기록 → EC2 Fluent Bit 가 사용
#
# 사용: bash setup.sh <비번호>
# =============================================================================
exec > /var/log/m3-setup.log 2>&1
set -x

NM="${1:-00}"
REGION=ap-northeast-1
CLUSTER=wsc-logging-cluster
NS=wsc-logging
SSM_PARAM=/wsc/module3/loki-endpoint

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# 노드 Ready 대기
for i in $(seq 1 30); do
  kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
  sleep 10
done

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# gp3 기본 StorageClass (Loki PVC 용)
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
YAML

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# ── Loki (SingleBinary, filesystem, PVC 10Gi, port 3100) ──────────────────────
cat > /tmp/loki-values.yaml <<'YAML'
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: 2024-01-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    retention_period: 168h
deploymentMode: SingleBinary
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi
    storageClass: gp3
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
chunksCache:
  enabled: false
resultsCache:
  enabled: false
gateway:
  enabled: false
test:
  enabled: false
lokiCanary:
  enabled: false
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
YAML

helm upgrade --install loki grafana/loki -n "$NS" -f /tmp/loki-values.yaml

# Loki 단일바이너리 Service 를 NLB(LoadBalancer)로 노출 (port 3100)
kubectl -n "$NS" annotate svc loki \
  service.beta.kubernetes.io/aws-load-balancer-type=external \
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type=instance \
  service.beta.kubernetes.io/aws-load-balancer-scheme=internet-facing --overwrite
kubectl -n "$NS" patch svc loki -p '{"spec":{"type":"LoadBalancer"}}'

# ── Grafana (NLB, Loki datasource, dashboard 4 panels) ────────────────────────
cat > /tmp/grafana-values.yaml <<YAML
adminUser: wsc2026-admin-${NM}
adminPassword: admin${NM}!
service:
  type: LoadBalancer
  port: 80
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.${NS}.svc.cluster.local:3100
        isDefault: true
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folderAnnotation: grafana_folder
    searchNamespace: ALL
YAML

helm upgrade --install grafana grafana/grafana -n "$NS" -f /tmp/grafana-values.yaml

# ── 대시보드 (WSC2026 Container Logs) — 4 LogQL 패널 ───────────────────────────
cat > /tmp/dashboard.json <<'JSON'
{
  "title": "WSC2026 Container Logs",
  "uid": "wsc2026-container-logs",
  "schemaVersion": 39,
  "refresh": "5s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "type": "logs", "title": "Any Log",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "{namespace=\"wsc-app-log\"}", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "INFO Log Count",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 8 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"INFO\" [1m])", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "ERROR Log Count",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 8 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"ERROR\" [1m])", "refId": "A" } ]
    },
    {
      "type": "timeseries", "title": "WARNING Log Count",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 8 },
      "datasource": { "type": "loki", "uid": "loki" },
      "targets": [ { "expr": "count_over_time({namespace=\"wsc-app-log\"} |= \"WARNING\" [1m])", "refId": "A" } ]
    }
  ]
}
JSON

kubectl -n "$NS" create configmap wsc2026-dashboard \
  --from-file=dashboard.json=/tmp/dashboard.json \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

# ── Loki NLB DNS 확정 후 SSM 기록 (EC2 Fluent Bit 가 polling) ──────────────────
for i in $(seq 1 40); do
  LOKI_LB=$(kubectl get svc loki -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [ -n "$LOKI_LB" ] && break
  sleep 15
done

if [ -n "$LOKI_LB" ]; then
  aws ssm put-parameter --name "$SSM_PARAM" --type String --overwrite \
    --value "$LOKI_LB" --region "$REGION"
  echo "Loki NLB = $LOKI_LB"
fi

echo "m3 setup done" > /tmp/m3_setup_done.txt
kubectl get svc -n "$NS"
