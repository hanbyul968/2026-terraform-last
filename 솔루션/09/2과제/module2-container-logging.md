# 모듈 2 — Container Logging (콘솔 가이드)

**리전: ap-southeast-2 (시드니)** — 우측 상단에서 반드시 변경

> 목표: EKS에 **Fluent Bit → Loki → Grafana** 로깅 파이프라인 + **nginx**를 배포하고,
> **ALB(경로 기반)**로 `/` → nginx, `/logging` → Grafana 접근. 규칙 외 경로는 404.

## 목표 리소스 이름
| 항목 | 이름 / 값 |
|------|-----------|
| VPC | `wsc2026-logging-vpc` (10.0.0.0/16) |
| 퍼블릭 서브넷 | `wsc2026-logging-public-subnet-a` (10.0.1.0/24, AZ a), `...-public-subnet-c` (10.0.2.0/24, AZ c) |
| 프라이빗 서브넷 | `...-private-subnet-a` (10.0.3.0/24), `...-private-subnet-c` (10.0.4.0/24) |
| IGW / NAT | `wsc2026-logging-internet-gateway` / `...-natgateway-a`, `...-natgateway-c` |
| 라우팅 테이블 | `...-public-routing-table`, `...-private-routing-table-a`, `...-private-routing-table-c` |
| EKS | `wsc2026-logging-cluster` (v1.35, **엔드포인트 프라이빗**) |
| NodeGroup | `wsc2026-logging-node-group` (AL2023, t3.medium, 2~4), 노드 태그 `wsc2026-logging-worker-node` |
| ALB | `wsc2026-logging-alb` (internet-facing) |
| Namespace | `logging` (fluent-bit, loki, grafana, nginx) |
| Grafana | admin / `wsc2026-logging-admin-61` |

---

## 1. VPC + 서브넷 (이름 정확히!)

**VPC 콘솔 → VPC 생성 → "VPC만"** 으로 만들고 나머지를 수동 생성(이름 태그를 정확히 맞추기 위해).

1. **VPC**: 이름 `wsc2026-logging-vpc`, CIDR `10.0.0.0/16` → 생성
2. **서브넷 4개** (VPC → 서브넷 → 서브넷 생성):
   | 이름 | AZ | CIDR |
   |------|----|----|
   | `wsc2026-logging-public-subnet-a` | ap-southeast-2a | 10.0.1.0/24 |
   | `wsc2026-logging-public-subnet-c` | ap-southeast-2c | 10.0.2.0/24 |
   | `wsc2026-logging-private-subnet-a` | ap-southeast-2a | 10.0.3.0/24 |
   | `wsc2026-logging-private-subnet-c` | ap-southeast-2c | 10.0.4.0/24 |
   - 퍼블릭 2개 → 태그 `kubernetes.io/role/elb`=`1`
   - 프라이빗 2개 → 태그 `kubernetes.io/role/internal-elb`=`1`
3. **IGW**: `wsc2026-logging-internet-gateway` 생성 → VPC에 연결
4. **NAT GW 2개** (VPC → NAT 게이트웨이 → 생성):
   - `wsc2026-logging-natgateway-a` → 서브넷 public-subnet-a, 새 EIP 할당
   - `wsc2026-logging-natgateway-c` → 서브넷 public-subnet-c, 새 EIP 할당
5. **라우팅 테이블**:
   - `wsc2026-logging-public-routing-table`: 라우트 `0.0.0.0/0 → IGW`, 퍼블릭 서브넷 2개 연결
   - `wsc2026-logging-private-routing-table-a`: `0.0.0.0/0 → natgateway-a`, private-subnet-a 연결
   - `wsc2026-logging-private-routing-table-c`: `0.0.0.0/0 → natgateway-c`, private-subnet-c 연결

---

## 2. EKS 클러스터 (프라이빗 엔드포인트)

1. IAM 역할 `wsc2026-logging-cluster-role` (EKS-Cluster 신뢰, `AmazonEKSClusterPolicy`)
2. **EKS → 클러스터 추가**:
   - 이름 `wsc2026-logging-cluster`, 버전 `1.35`, 역할 위 역할
   - 인증 모드: EKS API 및 ConfigMap
   - 네트워킹: VPC 선택, **서브넷 4개 모두**, 엔드포인트 액세스 **프라이빗만** (퍼블릭 끄기)
   - 생성 (약 10분)

## 3. 노드그룹

1. IAM 역할 `wsc2026-logging-nodegroup-role` (EC2 신뢰, 3개 정책: WorkerNode/CNI/ECR ReadOnly)
2. **EKS → 클러스터 → 노드 그룹 추가**:
   - 이름 `wsc2026-logging-node-group`, 역할 위 역할
   - AMI: **Amazon Linux 2023 (x86_64)**, 유형 `t3.medium`
   - 스케일링: 최소 2 / 최대 4 / 원하는 2
   - 서브넷: **프라이빗 2개**
   - 생성
3. 워커 노드 Name 태그를 `wsc2026-logging-worker-node`로: (노드그룹은 태그 전파가 제한적이라, 노드그룹 편집 → 태그에 `Name=wsc2026-logging-worker-node` 추가 또는 시작 템플릿 사용)

## 4. IRSA용 OIDC + ALB Controller 역할

1. OIDC 공급자 등록 (모듈1의 9단계와 동일 방식)
2. IAM 역할 `wsc2026-logging-alb-controller-role`:
   - 웹 자격증명 → OIDC → 신뢰 `system:serviceaccount:kube-system:aws-load-balancer-controller`
   - 정책: [AWS Load Balancer Controller IAM 정책](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json) 내용을 새 정책으로 만들어 연결
     (또는 `ElasticLoadBalancingFullAccess` + EC2 Describe/SecurityGroup + wafv2/shield/acm 등 넓게)

---

## 5. bastion EC2 (kubectl/helm 실행 — 프라이빗 클러스터라 필수)

> private endpoint라 CloudShell(일반)로는 접근 불가. **VPC 내부 bastion** 또는 **CloudShell VPC 환경(private-subnet-a)** 필요.

1. IAM 역할 `wsc2026-logging-bastion-role` (EC2 신뢰) → `AdministratorAccess` + `AmazonSSMManagedInstanceCore`
2. EC2 시작: 이름 `wsc2026-logging-bastion`, AL2023, t3.small, **public-subnet-a, 퍼블릭 IP 켜기**, 위 IAM 프로파일
3. EKS → 클러스터 → 액세스 → 액세스 항목: bastion 역할 ARN → 정책 `AmazonEKSClusterAdminPolicy`(cluster)
4. bastion 접속 (EC2 → 연결 → **Session Manager**), kubectl/helm 설치:
```bash
sudo su - ec2-user
curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
kubectl get nodes
```

---

## 6. ALB Controller 설치 (bastion)
```bash
ALB_ROLE=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role --query Role.Arn --output text)
VPC_ID=$(aws ec2 describe-vpcs --region ap-southeast-2 --filters "Name=tag:Name,Values=wsc2026-logging-vpc" --query "Vpcs[0].VpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=wsc2026-logging-cluster \
  --set region=ap-southeast-2 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=180s
```
> ❗ `region`/`vpcId` 빠지면 `failed to get VPC ID` CrashLoop. `serviceAccount.create=false` 쓰면 SA 없음 에러.

## 7. 로깅 스택 설치 (bastion)
```bash
kubectl create namespace logging
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts && helm repo update

helm install loki grafana/loki-stack -n logging

helm install grafana grafana/grafana -n logging \
  --set adminUser=admin --set adminPassword=wsc2026-logging-admin-61 \
  --set "grafana\.ini.server.serve_from_sub_path=true"

helm install fluent-bit fluent/fluent-bit -n logging

kubectl run nginx --image=nginx -n logging
kubectl expose pod nginx --port=80 -n logging
```

## 8. Ingress (ALB 생성)
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
    alb.ingress.kubernetes.io/success-codes: "200,302"   # grafana / 는 302 반환 → healthy 인정
spec:
  defaultBackend: { service: { name: nginx, port: { number: 80 } } }
  rules:
  - http:
      paths:
      - { path: /logging, pathType: Prefix, backend: { service: { name: grafana, port: { number: 80 } } } }
      - { path: /,        pathType: Prefix, backend: { service: { name: nginx,   port: { number: 80 } } } }
EOF
```

## 9. ALB DNS 확정 후 Grafana root_url 재설정
```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)
helm upgrade grafana grafana/grafana -n logging --reuse-values \
  --set "grafana\.ini.server.root_url=http://$ALB_DNS/logging" \
  --set "grafana\.ini.server.serve_from_sub_path=true"
```

---

## 10. 확인 (채점 2-4 ~ 2-6)
```bash
kubectl get po -A | grep fluent-bit
kubectl get po -n logging | grep -E 'loki|grafana|nginx'

ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)
curl -s -o /dev/null -w "/: %{http_code}\n" http://$ALB_DNS/           # 200
curl -s -L -o /dev/null -w "/logging: %{http_code}\n" http://$ALB_DNS/logging  # 200
curl -s -o /dev/null -w "/zzz: %{http_code}\n" http://$ALB_DNS/zzz     # 404
```
브라우저로 `http://<ALB_DNS>/logging` → admin / `wsc2026-logging-admin-61` 로그인 확인.

## 자주 나는 오류
- **`/logging` 503** → grafana 타깃 unhealthy. Ingress `success-codes: "200,302"` 확인 (grafana `/`는 302)
- **ALB Controller CrashLoop** → `region`/`vpcId` 명시 안 함, 또는 SA 미생성
- **helm: command not found** (CloudShell) → get-helm-3 설치 필요
- **kubectl timeout** → 프라이빗 클러스터. bastion 또는 CloudShell VPC 환경(private-subnet-a)에서 실행
- **NAT 이름** 은 과제지대로 `natgateway-a/c` (붙여쓰기)
