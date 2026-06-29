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

### 1. 자동 구성(setup.sh) 완료 대기 — [bastion]

bastion user_data가 **S3(`wsc2026-logging-setup-<계정ID>`)의 `setup.sh`를 받아 자동 실행**한다.
setup.sh가 하는 일: ALB Controller 설치 → namespace → Loki/Grafana(서브패스)/Fluent Bit/nginx → Ingress(ALB 생성) → ALB DNS 확정 후 grafana `root_url` 재설정.

```bash
# 완료 마커 (setup.sh 끝나면 생김)
cat /root/setup_done.txt 2>/dev/null || sudo cat /root/setup_done.txt   # "setup.sh done. ALB=..." 나오면 완료
# 진행 로그
sudo tail -f /var/log/setup.log   # (Ctrl+C로 빠져나오기)
```

> setup.sh는 ALB 생성까지 기다리느라 **5~8분** 걸린다. `setup_done.txt`가 생기면 끝.

### 2. 구성 검증 — [bastion]
```bash
# 파드 4종 Running (채점 2-4)
kubectl get po -A | grep fluent-bit
kubectl get po -n logging | grep -E 'loki|grafana|nginx'

# ALB Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# ALB DNS + 접속 (채점 2-5, 2-6)
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)
echo $ALB_DNS
curl -s -o /dev/null -w "/(nginx): %{http_code}\n" http://$ALB_DNS/
curl -s -L -o /dev/null -w "/logging(grafana): %{http_code}\n" http://$ALB_DNS/logging
curl -s -o /dev/null -w "/zzz(404): %{http_code}\n" http://$ALB_DNS/zzz
```
- `/` → 200(nginx), `/logging` → 200(grafana), 임의경로 → 404 면 정상.

### 수동 재실행 (setup.sh 실패/일부만 됐을 때) — [bastion]
```bash
# S3에서 다시 받아 실행
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sudo aws s3 cp s3://wsc2026-logging-setup-${ACCOUNT_ID}/setup.sh /root/setup.sh --region ap-southeast-2
sudo chmod +x /root/setup.sh && sudo /root/setup.sh
```

> setup.sh 내용을 바꾸려면 로컬에서 `module2/setup.sh` 수정 → `terraform apply`(S3 객체 갱신) →
> bastion에서 위 "수동 재실행" 또는 bastion 교체(`user_data_replace_on_change=true`라 apply 시 자동 교체).

> `/logging`이 503이면 grafana 타깃 unhealthy → setup.sh의 Ingress `success-codes: "200,302"` 확인.
> Ingress가 `DuplicateLoadBalancerName` 반복하면 terraform이 만든 동명 ALB 잔재 → `terraform apply`로 정리(이제 코드에 ALB 없음).

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
