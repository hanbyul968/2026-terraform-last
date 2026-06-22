# Module 1 - EKS Scaling (ap-northeast-2)

## 실행

> 폴더가 2개로 분리되어 있습니다. **각 폴더에서 그냥 `terraform apply` 하면 됩니다 (`-target` 불필요).**
> - `module1/`       → VPC, EKS 클러스터, 노드그룹, IAM, bastion (AWS 인프라)
> - `module1/k8s/`   → KEDA, Karpenter, k8s 매니페스트 (클러스터에 배포)
>
> 클러스터를 만드는 apply와 그 클러스터에 helm/kubectl을 배포하는 apply를 **같은 폴더에서 하면**
> endpoint가 미정이 되어 `Kubernetes cluster unreachable` 에러가 납니다. 그래서 폴더를 나눴습니다.
> k8s 폴더는 `../terraform.tfstate`(클러스터 상태)를 읽으므로 **반드시 module1 먼저, k8s 나중**.

**1단계 — 클러스터 폴더 (약 15~20분)**

```powershell
cd module1
terraform init
terraform apply --auto-approve
```

**1단계 완료 확인 — ACTIVE 떠야 2단계**

```powershell
aws eks describe-cluster --name wsi-eks --region ap-northeast-2 --query "cluster.status" --output text
```

**2단계 — k8s 폴더 (KEDA, Karpenter, 매니페스트)**

```powershell
cd k8s
terraform init
terraform apply --auto-approve
```

> 클러스터가 삭제되어 다시 만드는 경우에도 순서 동일: `module1` apply → ACTIVE 확인 → `module1/k8s` apply.

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

### 4. 배포파일 app.py 적용(import) 방식 & 검증

배포파일 `module1/app.py`는 컨테이너 이미지에 굽지 않고, **ConfigMap으로 컨테이너에 주입**한다:
- `module1/k8s/main.tf` 의 `kubectl_manifest.app_code` → `file("../app.py")` 를 ConfigMap `wsi-worker-code` 로 생성
- deployment가 그 ConfigMap을 `/app` 에 마운트 + `command: sh -c "pip install boto3 && python /app/app.py"` 로 기동
- 그래서 이미지(`python:3.11-slim`)는 채점 1-2 그대로 유지하면서, 파드는 CrashLoop 없이 실제 SQS 처리

**app.py가 실제로 적용됐는지 검증 (bastion):**
```bash
# (1) ConfigMap 존재 (DATA 1 = app.py)
kubectl get cm wsi-worker-code -n wsi-app

# (2) 컨테이너 명령이 pip+app.py 인지
kubectl get deploy wsi-worker-app -n wsi-app \
  -o jsonpath='{.spec.template.spec.containers[0].command}'; echo
#   → ["sh","-c","pip install --no-cache-dir --quiet boto3 && python /app/app.py"]

# (3) 부하 줘서 파드가 CrashLoop 아니라 Running 인지
QURL=$(aws sqs get-queue-url --queue-name wsi-task-queue --region ap-northeast-2 --query QueueUrl --output text)
for i in $(seq 1 30); do aws sqs send-message --queue-url $QURL --message-body "t-$i" >/dev/null; done
kubectl get pods -n wsi-app    # Running 1/1 이면 app.py 정상 기동
```

**app.py 수정 시 재배포:**
```bash
cd module1/k8s && terraform apply --auto-approve     # ConfigMap 갱신
kubectl rollout restart deploy/wsi-worker-app -n wsi-app   # 파드 교체
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
