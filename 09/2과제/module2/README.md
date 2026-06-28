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

> 실행 위치 구분:
> - **[로컬]** = Windows PowerShell (terraform apply, AWS CLI 조회, SSM 접속)
> - **[bastion]** = bastion EC2 안 (kubectl / helm). private endpoint 클러스터라 VPC 내부에서만 kubectl 가능.
>   terraform이 만든 bastion에 kubectl·helm·kubeconfig가 user_data로 자동 설치됨. (CloudShell 불필요)

### 0. bastion 접속 (★ kubectl/helm은 전부 여기서) — [로컬]

```powershell
# bastion 인스턴스 ID (terraform output 또는 태그로)
terraform output -raw bastion_id
# 또는
aws ec2 describe-instances --region ap-southeast-2 `
  --filters "Name=tag:Name,Values=wsc2026-logging-bastion" "Name=instance-state-name,Values=running" `
  --query "Reservations[0].Instances[0].InstanceId" --output text

# Session Manager 접속
aws ssm start-session --target <위 ID> --region ap-southeast-2
```

접속 후 ec2-user 로 전환 + 준비 확인:
```bash
sudo su - ec2-user
cat /home/ec2-user/bastion_ready.txt   # "done" 나오면 kubectl/helm 설치 완료
helm version; kubectl version --client
```

### 1. kubeconfig 확인 — [bastion]
```bash
# user_data가 자동 설정함. 안 됐으면 수동:
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
kubectl get nodes   # 노드 Ready 확인
```

### 2. ALB Controller 설치 — [bastion]

> ❗ 아래 4개 옵션은 **반드시 그대로**. 빠뜨리면 CrashLoop:
> - `region` / `vpcId` 누락 → `failed to get VPC ID ... context deadline exceeded` (명시하면 확실)
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

### 3. k8s 리소스 배포 — [bastion]
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

### 4. Ingress 배포 (ALB 생성) — [bastion]
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

### 5. ALB 생성 확인 (1~3분 소요) — [bastion]
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

### 5.5 Grafana root_url을 ALB DNS로 재설정 (/logging 정상 동작용) — [bastion]

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

## kubectl/helm 실행 환경 = bastion EC2

- 인스턴스: `wsc2026-logging-bastion` (public-subnet-a, t3.small)
- terraform이 user_data로 kubectl·helm·kubeconfig 자동 설치
- 접속: **[로컬 Windows]** `aws ssm start-session --target <bastion_id> --region ap-southeast-2`
- IAM: admin + EKS cluster-admin access entry (kubectl 권한)
- (CloudShell VPC 환경은 더 이상 필요 없음. 채점관이 CloudShell을 쓰려면 cloudshell SG도 그대로 남겨둠)

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
| Bastion      | wsc2026-logging-bastion (kubectl/helm 실행 호스트) |
