# Module 2 - Container Logging (ap-southeast-2)

> **ALB는 terraform이 아니라 Ingress(`logging-ingress`) + AWS Load Balancer Controller가 생성**합니다.
> terraform에서 ALB를 만들면 Ingress가 같은 이름(`wsc2026-logging-alb`)으로 또 만들려다
> `DuplicateLoadBalancerName` 충돌이 나서, terraform에는 ALB/타깃그룹/리스너를 두지 않습니다.
> terraform = VPC/EKS/노드/IAM, Ingress = ALB. (아래 5단계가 ALB를 만드는 단계)

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

### 0. CloudShell VPC 환경 접속 (★ 가장 중요)

클러스터는 **private endpoint**라, VPC 밖(일반 CloudShell)에서는 kubectl이 안 된다.
반드시 **CloudShell VPC 환경**을 아래 설정으로 띄운다:

- **VPC**: `wsc2026-logging-vpc`
- **Subnet**: `wsc2026-logging-private-subnet-a`  ← **private 서브넷만! (NAT 연결됨)**
- **Security group**: `wsc2026-logging-cloudshell-sg`

> ❗ public 서브넷에 띄우면 CloudShell ENI에 공인 IP가 없어 **인터넷이 안 됨**
> → `aws eks update-kubeconfig` 가 `Connect timeout on endpoint URL` 로 멈춤.
> private-subnet-a 는 NAT 경유로 인터넷 OK + VPC 내부라 private 클러스터도 OK.

접속 확인:
```bash
aws sts get-caller-identity   # 바로 응답하면 인터넷 OK (멈추면 잘못된 서브넷 → 환경 다시 생성)
```

> 클러스터 SG는 terraform에서 이미 열어둠: `443 from 10.0.0.0/16` + `cloudshell SG 전체 허용`.

### 1. helm 설치 (CloudShell엔 helm 없음)
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version   # 안 잡히면: export PATH=$PATH:/usr/local/bin:~/.local/bin
```

### 2. kubeconfig 설정
```bash
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
kubectl get nodes   # 노드 Ready 확인
```

### 3. ALB Controller 설치

> ❗ 아래 4개 옵션은 **반드시 그대로**. 빠뜨리면 CrashLoop:
> - `region` / `vpcId` 누락 → `failed to get VPC ID ... context deadline exceeded`
>   (CloudShell엔 인스턴스 메타데이터(IMDS)가 없어 VPC ID 자동 조회 불가)
> - `serviceAccount.create=true` + `serviceAccount.name` + role-arn 어노테이션 누락 → SA 없음 →
>   `MountVolume.SetUp failed ... serviceaccounts "aws-load-balancer-controller" not found`
>
> ⚠️ **절대 `serviceAccount.create=false` 로 install/upgrade 하지 말 것** (SA가 안 만들어져 위 에러 발생).

```bash
ALB_ROLE=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role \
  --query Role.Arn --output text)
VPC_ID=$(aws ec2 describe-vpcs --region ap-southeast-2 \
  --filters "Name=tag:Name,Values=wsc2026-logging-vpc" \
  --query "Vpcs[0].VpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wsc2026-logging-cluster \
  --set region=ap-southeast-2 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"

# 확인: SA 존재 + 파드 2개 Running 1/1
kubectl get sa aws-load-balancer-controller -n kube-system
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

> 이미 망가진 상태(CrashLoop/ContainerCreating/SA 없음)면 **깨끗이 지우고 위 명령 재실행**:
> ```bash
> helm uninstall aws-load-balancer-controller -n kube-system
> ```

### 4. k8s 리소스 배포
```bash
kubectl create namespace logging

# Loki
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
helm install loki grafana/loki-stack -n logging

# Grafana — /logging 서브패스로 서비스해야 함 (ALB가 /logging 경로 그대로 전달)
# ALB DNS는 Ingress 생성 후 정해지므로, 먼저 설치하고 5단계 뒤 ALB DNS로 root_url 재설정(아래 6.5단계)
helm install grafana grafana/grafana -n logging \
  --set adminUser=admin \
  --set adminPassword=wsc2026-logging-admin-61 \
  --set "grafana\.ini.server.serve_from_sub_path=true"

# Fluent Bit
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit -n logging

# nginx
kubectl run nginx --image=nginx -n logging
kubectl expose pod nginx --port=80 -n logging
```

### 5. Ingress 배포 (ALB 생성)
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
    # grafana는 헬스체크 경로 / 에서 302(로그인 리다이렉트) 반환 → 302도 healthy로 인정해야 503 안 남
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
EOF
```

### 6. ALB 생성 확인 (1~3분 소요)
```bash
# Ingress의 ADDRESS에 DNS가 뜨면 ALB 생성 완료
kubectl get ingress -n logging

# 또는 직접 조회
aws elbv2 describe-load-balancers --names wsc2026-logging-alb \
  --region ap-southeast-2 --query "LoadBalancers[].DNSName" --output text

# 접속 테스트 (ALB active 후)
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)
curl -s -o /dev/null -w "/(nginx): %{http_code}\n" http://$ALB_DNS/
curl -s -o /dev/null -w "/logging(grafana): %{http_code}\n" http://$ALB_DNS/logging
```

### 6.5 Grafana root_url을 ALB DNS로 재설정 (/logging 정상 동작용)

ALB DNS는 Ingress 생성 후에야 정해지므로, 그 값으로 grafana `root_url`을 채워준다:
```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)

helm upgrade grafana grafana/grafana -n logging --reuse-values \
  --set "grafana\.ini.server.root_url=http://$ALB_DNS/logging" \
  --set "grafana\.ini.server.serve_from_sub_path=true"

# 타깃 healthy + /logging 200 확인 (1~2분 후)
curl -s -L -o /dev/null -w "/logging: %{http_code}\n" http://$ALB_DNS/logging
curl -s -o /dev/null -w "/zzz(404): %{http_code}\n" http://$ALB_DNS/zzz
```

> `/logging`이 **503**이면 grafana 타깃이 unhealthy인 것:
> - 위 `success-codes: "200,302"` 가 Ingress에 들어갔는지 확인 (grafana `/`는 302 반환)
> - 타깃 헬스: `aws elbv2 describe-target-health --target-group-arn <grafana-TG-ARN> --region ap-southeast-2`

> ❗ Ingress가 `DuplicateLoadBalancerName ... exists, but with different settings` 로그를 반복하면,
> terraform이 만든 같은 이름 ALB가 남아있는 것. `module2`에서 `terraform apply`로 terraform ALB를
> 제거(이제 코드에 ALB 없음)하면 컨트롤러가 자동으로 자기 ALB를 생성한다.

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
