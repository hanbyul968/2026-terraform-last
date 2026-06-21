# Module 1 - EKS Scaling (ap-northeast-2)

## 실행

> ⚠️ **반드시 2단계로 실행. 1단계(클러스터 ACTIVE) 완료 전에는 절대 전체 apply 금지.**
>
> 클러스터를 만드는 같은 apply에서는 endpoint가 "known after apply"(미정)가 되어
> helm/kubectl provider가 localhost로 폴백 → `Kubernetes cluster unreachable` /
> `dial tcp [::1]:80` 에러. 코드 버그가 아니라 Terraform 구조적 제약이라 단계 분리가 유일한 해법.

```powershell
terraform init
```

**1단계 — VPC + EKS 클러스터 + 노드그룹 생성 (약 15~20분)**

```powershell
terraform apply "-target=aws_eks_node_group.system" "-target=aws_instance.bastion" --auto-approve
```

**1단계 완료 확인 — ACTIVE가 나와야 2단계 진행**

```powershell
aws eks describe-cluster --name wsi-eks --region ap-northeast-2 --query "cluster.status" --output text
```

**2단계 — 나머지 전체 (IRSA, KEDA, Karpenter, k8s 리소스)**

```powershell
terraform apply --auto-approve
```

> 클러스터가 AWS에서 삭제되어 다시 만드는 경우에도 위 순서 그대로. 전체 apply부터 하면 매번 에러.

## apply 후 할 일

### 1. bastion 접속 (Session Manager)

```bash
# bastion EC2 ID 확인
aws ec2 describe-instances --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=wsi-bastion" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text

# Session Manager 접속
aws ssm start-session --target <위에서 나온 ID> --region ap-northeast-2
```

### 2. bastion 안에서 kubectl 연결

```bash
# kubeconfig 설정 (user_data에서 자동 실행되지만 안 됐으면 수동)
aws eks update-kubeconfig --name wsi-eks --region ap-northeast-2

# 연결 확인
kubectl get nodes
```

### 3. 배포 상태 확인

```bash
kubectl get all -n wsi-app
kubectl get scaledobject -n wsi-app
kubectl get nodepool
kubectl get ec2nodeclass
```

## 채점 정보

| 항목           | 값                                                              |
| -------------- | --------------------------------------------------------------- |
| EKS Cluster    | wsi-eks                                                         |
| NodeGroup      | wsi-system (t3.medium, 2/2/2, taint dedicated=addon:NoSchedule) |
| SQS Queue      | wsi-task-queue                                                  |
| Namespace      | wsi-app                                                         |
| Deployment     | wsi-worker-app (python:3.11-slim)                               |
| ServiceAccount | wsi-worker-sa (IRSA)                                            |
| ScaledObject   | wsi-keda-scaler (SQS trigger, min=0, max=20)                    |
| NodePool       | wsi-nodepool (c5)                                               |
| EC2NodeClass   | wsi-nodeclass                                                   |
| IRSA Role      | wsi-worker-role                                                 |

## 채점 5번 동작 원리

1. 채점스크립트가 SQS에 200개 메시지 전송
2. KEDA가 SQS depth 감지 → Pod 스케일아웃 (max 20)
3. Karpenter가 c5 노드 프로비저닝
4. Pod replicas ≥ 15 && Karpenter node ≥ 1 확인 (3분 이내)
