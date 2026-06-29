#!/bin/bash
# =============================================================================
# module3 deploy_k8s.sh  (Linux bastion 에서 실행)
#   module3 terraform apply(VPC+EKS+노드그룹) 후 k8s/Helm 단계를 수행한다.
#     1) kubeconfig 연결
#     2) log-generator 배포 (wsc2026-app, Service LoadBalancer)
#     3) Helm: Loki -> OTel Collector -> Prometheus -> Fluent Bit -> Grafana
#     4) Grafana 대시보드(wsc2026-app-logs) ConfigMap 주입
#
#   필요 환경변수 (상위 deploy.sh 가 module3 terraform output 으로 주입):
#     CLUSTER_NAME  (wsc2026-logging-cluster)
#     REGION        (ap-northeast-1)
#     MODULE_DIR    (module3 디렉터리 경로; helm/, k8s/, app/ 포함)
#   선택:
#     GRADER_ARN    (CloudShell 채점 주체 IAM ARN; 지정 시 EKS access entry 부여)
# =============================================================================
set -euo pipefail

: "${CLUSTER_NAME:=wsc2026-logging-cluster}"
: "${REGION:=ap-northeast-1}"
: "${MODULE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NS=wsc2026-logging

echo "[k8s] kubeconfig 연결: $CLUSTER_NAME ($REGION)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# (선택) CloudShell 채점 주체에 cluster admin access entry 부여
if [ -n "${GRADER_ARN:-}" ]; then
  aws eks create-access-entry --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --principal-arn "$GRADER_ARN" --type STANDARD 2>/dev/null || true
  aws eks associate-access-policy --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --principal-arn "$GRADER_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster 2>/dev/null || true
fi

# ---- 1) log-generator 배포 (app.py 를 ConfigMap 에 주입) ----
echo "[k8s] log-generator 배포..."
RENDERED=/tmp/log-generator.yaml
python3 - "$MODULE_DIR/k8s/deployment.yaml" "$MODULE_DIR/app/app.py" > "$RENDERED" <<'PY'
import sys
tmpl = open(sys.argv[1], encoding="utf-8").read()
app = open(sys.argv[2], encoding="utf-8").read()
indented = "\n".join(("    " + line) if line else "" for line in app.splitlines())
sys.stdout.write(tmpl.replace("__APP_PY__", indented))
PY
kubectl apply -f "$RENDERED"

# ---- 2) Helm 저장소 ----
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# ---- 3) Loki (SingleBinary) ----
echo "[k8s] Loki..."
helm upgrade --install wsc2026-loki grafana/loki -n "$NS" \
  -f "$MODULE_DIR/helm/loki-values.yaml" --wait --timeout 15m

# ---- 4) OTel Collector ----
echo "[k8s] OpenTelemetry Collector..."
helm upgrade --install wsc2026-otel-collector open-telemetry/opentelemetry-collector -n "$NS" \
  -f "$MODULE_DIR/helm/otel-values.yaml" --wait --timeout 10m

# ---- 5) Prometheus ----
echo "[k8s] Prometheus..."
helm upgrade --install wsc2026-prometheus prometheus-community/prometheus -n "$NS" \
  -f "$MODULE_DIR/helm/prometheus-values.yaml" --wait --timeout 10m

# ---- 6) Fluent Bit (DaemonSet) ----
echo "[k8s] Fluent Bit..."
helm upgrade --install wsc2026-fluent-bit fluent/fluent-bit -n "$NS" \
  -f "$MODULE_DIR/helm/fluent-bit-values.yaml" --wait --timeout 10m

# ---- 7) Grafana 대시보드 ConfigMap + Grafana ----
echo "[k8s] Grafana 대시보드 ConfigMap..."
kubectl create configmap wsc2026-app-logs-dashboard -n "$NS" \
  --from-file=wsc2026-app-logs.json="$MODULE_DIR/helm/dashboard.json" \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

echo "[k8s] Grafana..."
helm upgrade --install wsc2026-grafana grafana/grafana -n "$NS" \
  -f "$MODULE_DIR/helm/grafana-values.yaml" --wait --timeout 10m

echo ""
echo "[k8s] 완료. 엔드포인트:"
echo "  log-generator : kubectl get svc log-generator -n wsc2026-app"
echo "  grafana       : kubectl get svc wsc2026-grafana -n $NS  (admin / Skill53@@)"
