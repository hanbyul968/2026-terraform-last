#!/bin/bash
# bastion에서 실행 — module2 k8s 리소스 자동 구성
# ALB Controller + Loki/Grafana/Fluent Bit/nginx + Ingress(ALB 생성) + grafana /logging 서브패스
# (ALB는 Ingress가 생성. terraform에는 ALB/TG 없음)
exec > /var/log/setup.log 2>&1
set -x

REGION=ap-southeast-2
CLUSTER=wsc2026-logging-cluster

aws eks update-kubeconfig --name $CLUSTER --region $REGION

# 노드 Ready 대기
for i in $(seq 1 30); do
  kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
  sleep 10
done

ALB_ROLE=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role --query Role.Arn --output text)
VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
  --filters "Name=tag:Name,Values=wsc2026-logging-vpc" --query "Vpcs[0].VpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# ── ALB Controller (region/vpcId/SA 필수) ───────────────────────
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set region=$REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=180s

# ── 로깅 스택 ───────────────────────────────────────────────────
kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install loki grafana/loki-stack -n logging

helm upgrade --install grafana grafana/grafana -n logging \
  --set adminUser=admin \
  --set adminPassword=wsc2026-logging-admin-61 \
  --set "grafana\.ini.server.serve_from_sub_path=true" \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Loki' \
  --set 'datasources.datasources\.yaml.datasources[0].type=loki' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://loki:3100' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy'

helm upgrade --install fluent-bit fluent/fluent-bit -n logging

kubectl get pod nginx -n logging >/dev/null 2>&1 || kubectl run nginx --image=nginx -n logging
kubectl get svc nginx -n logging >/dev/null 2>&1 || kubectl expose pod nginx --port=80 -n logging

# ── Ingress (ALB 생성) ──────────────────────────────────────────
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: logging-ingress
  namespace: logging
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/load-balancer-name: wsc2026-logging-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/success-codes: "200,302"
spec:
  defaultBackend:
    service:
      name: nginx
      port:
        number: 80
  rules:
  - http:
      paths:
      - path: /logging
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
YAML

# ── ALB DNS 확정 후 grafana root_url 재설정 (/logging 정상 동작) ──
for i in $(seq 1 40); do
  ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb \
    --region $REGION --query "LoadBalancers[0].DNSName" --output text 2>/dev/null)
  [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ] && break
  sleep 15
done

if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  helm upgrade grafana grafana/grafana -n logging --reuse-values \
    --set "grafana\.ini.server.root_url=http://$ALB_DNS/logging" \
    --set "grafana\.ini.server.serve_from_sub_path=true"
fi

echo "setup.sh done. ALB=$ALB_DNS" > /root/setup_done.txt
kubectl get po -n logging
