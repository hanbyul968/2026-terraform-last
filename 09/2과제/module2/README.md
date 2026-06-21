# Module 2 - Container Logging (ap-southeast-2)

## 실행

> ⚠️ **재실행 시 (이미 한 번 apply한 경우)** — 서브넷 충돌 오류가 나면 아래 정리 먼저 실행 (PowerShell):

```powershell
# 기존 public_b 서브넷 ID (충돌 오류 메시지에서 확인)
$OLD_SUBNET = "subnet-06d7af19cf8c6601d"

# 라우트 테이블 연결 해제
$ASSOC_ID = aws ec2 describe-route-tables --region ap-southeast-2 `
  --filters "Name=association.subnet-id,Values=$OLD_SUBNET" `
  --query "RouteTables[0].Associations[?SubnetId=='$OLD_SUBNET'].RouteTableAssociationId" `
  --output text
if ($ASSOC_ID -and $ASSOC_ID -ne "None") {
  aws ec2 disassociate-route-table --association-id $ASSOC_ID --region ap-southeast-2
}

# 서브넷 삭제
aws ec2 delete-subnet --subnet-id $OLD_SUBNET --region ap-southeast-2

# terraform state에서 제거
terraform state rm "aws_subnet.public_b"
terraform state rm "aws_route_table_association.public_b"
```

```bash
terraform init
terraform apply --auto-approve
```

## apply 후 할 일

### 1. kubeconfig 설정
```bash
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
kubectl get nodes
```

### 2. ALB Controller 설치
```bash
ALB_ROLE=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role \
  --query Role.Arn --output text)

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wsc2026-logging-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"
```

### 3. k8s 리소스 배포
```bash
kubectl create namespace logging

# Loki
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm install loki grafana/loki-stack -n logging

# Grafana
helm install grafana grafana/grafana -n logging \
  --set adminUser=admin \
  --set adminPassword=wsc2026-logging-admin-61

# Fluent Bit
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit -n logging

# nginx
kubectl run nginx --image=nginx -n logging
kubectl expose pod nginx --port=80 -n logging
```

### 4. Ingress 배포 (ALB 생성)
```bash
kubectl apply -f - <<'EOF'
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
EOF
```

### 5. ALB DNS 확인
```bash
aws elbv2 describe-load-balancers --names wsc2026-logging-alb \
  --region ap-southeast-2 --query "LoadBalancers[].DNSName" --output text
```

## CloudShell VPC Environment (채점용)

- VPC: wsc2026-logging-vpc
- Subnet: wsc2026-logging-private-subnet-a
- Security Group: wsc2026-logging-cloudshell-sg

## Grafana 접속

```
http://<ALB DNS>/logging
ID: admin
PW: wsc2026-logging-admin-61
```

## 채점 정보

| 항목         | 값                                    |
| ------------ | ------------------------------------- |
| VPC          | wsc2026-logging-vpc (10.0.0.0/16)     |
| EKS Cluster  | wsc2026-logging-cluster (v1.35)       |
| NodeGroup    | wsc2026-logging-node-group (t3.medium, 2~4) |
| ALB          | wsc2026-logging-alb (internet-facing) |
| Namespace    | logging                               |
| Grafana PW   | wsc2026-logging-admin-61              |
