# 2과제 테라폼 - 실행법 & 변경 가이드

---

## 실행 순서

### 사전 준비

```bash
# AWS CLI 자격증명 확인
aws sts get-caller-identity

# Terraform 설치 확인
terraform version
```

---

### Module 1 — EKS Scaling (ap-northeast-2)

> ⚠️ **폴더 2개로 분리됨.** `module1/` = AWS 인프라+클러스터, `module1/k8s/` = KEDA/Karpenter/매니페스트.
> 클러스터 생성과 helm 배포를 같은 폴더에서 하면 endpoint 미정으로 `cluster unreachable` 에러가 나므로 분리함.
> **반드시 `module1` 먼저(ACTIVE까지) → 그 다음 `module1/k8s`.** 각 폴더는 그냥 `terraform apply` (`-target` 불필요).

**1. 클러스터 생성** (약 15~20분)

```bash
cd module1
terraform init
terraform apply -auto-approve

# ACTIVE 떠야 다음 단계
aws eks describe-cluster --name wsi-eks --region ap-northeast-2 --query "cluster.status" --output text
```

**2. k8s 레이어 배포** (KEDA, Karpenter, 매니페스트)

```bash
cd k8s
terraform init
terraform apply -auto-approve
```

**3. (선택) bastion 접속해서 상태 확인** (콘솔 → EC2 → Session Manager 또는 SSH)

```bash
# output에서 IP 확인
terraform output bastion_public_ip

# SSH 접속
ssh ec2-user@<bastion_public_ip>
```

**3. bastion 안에서 kubectl 연결** (user_data가 자동 실행하지만 안 됐으면 수동)

```bash
# kubectl 없으면 설치
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kubeconfig 설정
aws eks update-kubeconfig --name wsi-eks --region ap-northeast-2

# 연결 확인
kubectl get nodes
```

**4. 배포 상태 확인** (bastion 안에서)

```bash
aws eks update-kubeconfig --name wsi-eks --region ap-northeast-2
kubectl get all -n wsi-app
kubectl get scaledobject -n wsi-app
kubectl get nodepool
kubectl get ec2nodeclass
```

---

### Module 2 — Container Logging (ap-southeast-2)

**1. terraform apply**

```bash
cd module2
terraform init
terraform apply -auto-approve
```

> ⚠️ 이후 단계는 **CloudShell VPC 환경**(private-subnet-a + `wsc2026-logging-cloudshell-sg`)에서 실행.
> private endpoint 클러스터라 일반 CloudShell/VPC 밖에선 kubectl 안 됨. (상세는 `module2/README.md` 0단계)

**2. helm 설치** (CloudShell엔 helm 없음 → `helm: command not found` 방지)

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version   # 안 잡히면: export PATH=$PATH:/usr/local/bin:~/.local/bin
```

**3. kubeconfig 설정**

```bash
aws eks update-kubeconfig --name wsc2026-logging-cluster --region ap-southeast-2
kubectl get nodes
```

**4. ALB Controller 설치** (`region`/`vpcId` 필수 — 없으면 VPC ID 못 찾아 CrashLoop)

```bash
ALB_ROLE=$(aws iam get-role --role-name wsc2026-logging-alb-controller-role \
  --query Role.Arn --output text)
VPC_ID=$(aws ec2 describe-vpcs --region ap-southeast-2 \
  --filters "Name=tag:Name,Values=wsc2026-logging-vpc" --query "Vpcs[0].VpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wsc2026-logging-cluster \
  --set region=ap-southeast-2 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE"

kubectl get sa aws-load-balancer-controller -n kube-system   # SA 존재 확인
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=120s
```

**5. k8s 리소스 배포**

```bash
kubectl create namespace logging

# Loki
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack -n logging

# Grafana (/logging 서브패스 서비스)
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

**6. Ingress 배포 (ALB 생성)**

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

**7. ALB DNS 확인 + Grafana root_url 재설정**

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --names wsc2026-logging-alb \
  --region ap-southeast-2 --query "LoadBalancers[0].DNSName" --output text)
echo $ALB_DNS

# grafana를 ALB DNS의 /logging 서브패스로 재설정 (안 하면 /logging 접속 깨짐)
helm upgrade grafana grafana/grafana -n logging --reuse-values \
  --set "grafana\.ini.server.root_url=http://$ALB_DNS/logging" \
  --set "grafana\.ini.server.serve_from_sub_path=true"

# 접속 테스트 (1~2분 후): / →200(nginx), /logging →200(grafana), 임의경로 →404
curl -s -o /dev/null -w "/: %{http_code}\n" http://$ALB_DNS/
curl -s -L -o /dev/null -w "/logging: %{http_code}\n" http://$ALB_DNS/logging
curl -s -o /dev/null -w "/zzz: %{http_code}\n" http://$ALB_DNS/zzz
```

> `/logging`이 503이면 grafana 타깃 unhealthy → Ingress의 `success-codes: "200,302"` 들어갔는지 확인.

---

### Module 3 — MSK (ap-northeast-3)

**1. terraform apply**

```bash
cd module3
terraform init
terraform apply -auto-approve
#   var.competitor_number 를 물어봄 → 본인 비번호 입력 (예: 01)
# 또는 바로 넘기기:
# terraform apply -auto-approve -var="competitor_number=01"
```

**2. wsc-app-ec2에 접속** (콘솔 → EC2 → Session Manager)

**3. MSK 토픽 생성** (app EC2 안에서 실행)

```bash
# MSK 브로커 주소 확인
CLUSTER_ARN=$(aws kafka list-clusters --region ap-northeast-3 \
  --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
  --region ap-northeast-3 --query BootstrapBrokerString --output text)

# 토픽 생성
/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create \
  --bootstrap-server $BOOTSTRAP --topic order-events --partitions 3 --replication-factor 2

/home/ec2-user/kafka_2.13-3.5.1/bin/kafka-topics.sh --create \
  --bootstrap-server $BOOTSTRAP --topic order-events-dlq --partitions 1 --replication-factor 2
```

**4. consumer 실행** (백그라운드 — `--bootstrap-servers`, `--bucket` 인자 필수)

```bash
nohup python3 /home/ec2-user/ec2_consumer.py \
  --bootstrap-servers $BOOTSTRAP \
  --bucket wsc-msk-order-data-<비번호>-bucket \
  >> /tmp/consumer.log 2>&1 &
echo "Consumer PID: $!"
sleep 3 && cat /tmp/consumer.log   # "[EC2 Consumer] 시작 ..." 나오면 OK
# (로그가 Permission denied면 root 소유 파일 때문 → /tmp 경로 사용)
```

**5. Lambda ESM Enabled 확인 + 데이터 채우기** (채점 전 필수)

> Lambda/DynamoDB 명령은 EC2 역할에 권한이 있어야 함(`terraform apply`로 반영됨).
> 권한 추가 전이라 `AccessDenied`면 **CloudShell/로컬(admin)**에서 실행. ESM은 terraform에서 `enabled=true`라 이미 켜져 있음.

```bash
# Lambda 트리거 활성화 확인 (Enabled 아니면 enable)
ESM_UUID=$(aws lambda list-event-source-mappings --function-name msk-order-consumer \
  --region ap-northeast-3 --query "EventSourceMappings[0].UUID" --output text)
aws lambda update-event-source-mapping --uuid $ESM_UUID --enabled --region ap-northeast-3

# 메시지 100건 발행 → Lambda가 DynamoDB, consumer가 S3에 저장
for i in $(seq 1 100); do
  echo "{\"orderId\":\"uuid-$(cat /proc/sys/kernel/random/uuid)\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S).000Z\",\"region\":\"ap-northeast-3\",\"product\":{\"id\":\"P001\",\"name\":\"item\",\"price\":1000},\"quantity\":1,\"totalPrice\":1000,\"status\":\"CREATED\"}" | \
  /home/ec2-user/kafka_2.13-3.5.1/bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP --topic order-events
done

sleep 15
aws dynamodb scan --table-name order-records --select COUNT --query Count --output text --region ap-northeast-3
aws s3 ls s3://wsc-msk-order-data-<비번호>-bucket/orders/ --recursive | head
```

> ❗ `python3 ec2_consumer.py` 만 치면 `arguments are required: --bootstrap-servers, --bucket` 에러.
> 반드시 위처럼 인자를 넣어야 한다.

---

### Module 4 — REST API (ap-southeast-1)

**1. terraform apply**

```bash
cd module4
terraform init
terraform apply -auto-approve
```

**2. 동작 확인**

```bash
API_ID=$(aws apigateway get-rest-apis --region ap-southeast-1 \
  --query "items[?name=='wsc2026-worldschool-api'].id" --output text)
URL=https://${API_ID}.execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage

# POST
curl -X POST -d '{"admission_year": 2026, "student_name":"홍길동"}' \
  -w "\n%{http_code}\n" $URL

# GET 전체
curl -X GET -w "\n%{http_code}\n" $URL

# GET 특정
curl -G -d "admission_year=2026" --data-urlencode "student_name=홍길동" \
  -w "\n%{http_code}\n" $URL
```

---

## 전체 실행 순서 요약

```
1. module1 → terraform apply   # EKS + KEDA + Karpenter (ap-northeast-2)
2. module2 → terraform apply   # EKS + ALB (ap-southeast-2)
3. module3 → terraform apply   # MSK + Lambda + DynamoDB (ap-northeast-3)
4. module4 → terraform apply   # API GW + Lambda + DynamoDB (ap-southeast-1)
```

각 모듈은 독립적이므로 **순서 무관, 동시 실행 가능**합니다.

---

과제 값이 바뀔 때 어느 파일의 어느 부분을 수정해야 하는지 정리한 문서입니다.

---

## Module 1 — EKS Scaling

> 파일 2곳: AWS 리소스 = `module1/main.tf`, k8s 리소스(helm/kubectl) = `module1/k8s/main.tf`.
> 아래 표에서 `kubectl_manifest.*`, `helm_release.*` 는 **`module1/k8s/main.tf`** 에 있음. 나머지는 `module1/main.tf`.

| 바뀌는 값                                                          | 수정 위치                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **EKS 클러스터 이름** (`wsi-eks`)                          | `aws_eks_cluster.main.name` + `aws_sqs_queue`, `aws_subnet.pub_a/b/priv_a/b` 의 kubernetes.io 태그 key + `aws_nat_gateway` user_data의 `--name wsi-eks` + `kubectl_manifest.nodeclass` 의 `karpenter.sh/discovery` 값 + `kubectl_manifest.nodepool` + IRSA Condition의 `system:serviceaccount:*` + Helm `settings.clusterName` |
| **Region** (`ap-northeast-2`)                              | `provider "aws"` → `region` + `aws_iam_role_policy.keda_sqs` 의 `awsRegion` + `kubectl_manifest.scaledobject` 의 `awsRegion` + bastion user_data의 `--region`                                                                                                                                                                       |
| **VPC CIDR** (`10.0.0.0/16`)                               | `aws_vpc.main.cidr_block`                                                                                                                                                                                                                                                                                                                        |
| **Public 서브넷 CIDR** (`10.0.1.0/24`, `10.0.2.0/24`)    | `aws_subnet.pub_a.cidr_block`, `aws_subnet.pub_b.cidr_block`                                                                                                                                                                                                                                                                                   |
| **Private 서브넷 CIDR** (`10.0.11.0/24`, `10.0.12.0/24`) | `aws_subnet.priv_a.cidr_block`, `aws_subnet.priv_b.cidr_block`                                                                                                                                                                                                                                                                                 |
| **서브넷 AZ**                                                | `aws_subnet.pub_a/pub_b/priv_a/priv_b` 의 `availability_zone`                                                                                                                                                                                                                                                                                  |
| **EKS Kubernetes 버전** (`1.31`)                           | `aws_eks_cluster.main.version`                                                                                                                                                                                                                                                                                                                   |
| **System NodeGroup 이름** (`wsi-system`)                   | `aws_eks_node_group.system.node_group_name`                                                                                                                                                                                                                                                                                                      |
| **System NodeGroup 인스턴스 타입** (`t3.medium`)           | `aws_eks_node_group.system.instance_types`                                                                                                                                                                                                                                                                                                       |
| **System NodeGroup 스케일링** (desired/min/max = 2/2/2)      | `aws_eks_node_group.system.scaling_config`                                                                                                                                                                                                                                                                                                       |
| **SQS 큐 이름** (`wsi-task-queue`)                         | `aws_sqs_queue.main.name` + `kubectl_manifest.scaledobject` 의 `queueURL` (자동 참조)                                                                                                                                                                                                                                                        |
| **앱 Namespace** (`wsi-app`)                               | `kubectl_manifest.namespace` + 모든 kubectl_manifest 의 `namespace: wsi-app` + IRSA Condition의 `serviceaccount:wsi-app:*`                                                                                                                                                                                                                   |
| **Deployment 이름** (`wsi-worker-app`)                     | `kubectl_manifest.deployment` 의 `name` + `kubectl_manifest.scaledobject` 의 `scaleTargetRef.name`                                                                                                                                                                                                                                         |
| **ServiceAccount 이름** (`wsi-worker-sa`)                  | `kubectl_manifest.service_account.name` + `kubectl_manifest.deployment` 의 `serviceAccountName` + IRSA Condition                                                                                                                                                                                                                             |
| **컨테이너 이미지** (`python:3.11-slim`)                   | `kubectl_manifest.deployment` 의 `image`                                                                                                                                                                                                                                                                                                       |
| **컨테이너 리소스** (cpu/memory)                             | `kubectl_manifest.deployment` 의 `resources.requests/limits`                                                                                                                                                                                                                                                                                   |
| **ScaledObject 이름** (`wsi-keda-scaler`)                  | `kubectl_manifest.scaledobject.metadata.name`                                                                                                                                                                                                                                                                                                    |
| **KEDA min/max replicas** (0/20)                             | `kubectl_manifest.scaledobject` 의 `minReplicaCount` / `maxReplicaCount`                                                                                                                                                                                                                                                                     |
| **KEDA queueLength** (`1`)                                 | `kubectl_manifest.scaledobject` 의 `triggers[0].metadata.queueLength`                                                                                                                                                                                                                                                                          |
| **NodePool 이름** (`wsi-nodepool`)                         | `kubectl_manifest.nodepool.metadata.name`                                                                                                                                                                                                                                                                                                        |
| **EC2NodeClass 이름** (`wsi-nodeclass`)                    | `kubectl_manifest.nodeclass.metadata.name` + `kubectl_manifest.nodepool` 의 `nodeClassRef.name`                                                                                                                                                                                                                                              |
| **Karpenter 인스턴스 패밀리** (`c5`)                       | `kubectl_manifest.nodepool` 의 `requirements[0].values`                                                                                                                                                                                                                                                                                        |

---

## Module 2 — Container Logging (`module2/main.tf`)

| 바뀌는 값                                                                            | 수정 위치                                                                                                      |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| **Region** (`ap-southeast-2`)                                                | `provider "aws"` → `region` + 모든 `availability_zone` 접두사                                           |
| **VPC 이름 태그** (`wsc2026-logging-vpc`)                                    | `aws_vpc.main.tags.Name`                                                                                     |
| **VPC CIDR** (`10.0.0.0/16`)                                                 | `aws_vpc.main.cidr_block`                                                                                    |
| **Public 서브넷 A CIDR/AZ** (`10.0.1.0/24`, `ap-southeast-2a`)             | `aws_subnet.public_a.cidr_block` / `availability_zone`                                                     |
| **Public 서브넷 C CIDR/AZ** (`10.0.2.0/24`, `ap-southeast-2c`)             | `aws_subnet.public_c.cidr_block` / `availability_zone`                                                     |
| **Private 서브넷 A CIDR/AZ** (`10.0.3.0/24`, `ap-southeast-2a`)            | `aws_subnet.private_a.cidr_block` / `availability_zone`                                                    |
| **Private 서브넷 C CIDR/AZ** (`10.0.4.0/24`, `ap-southeast-2c`)            | `aws_subnet.private_c.cidr_block` / `availability_zone`                                                    |
| **서브넷 이름 태그**                                                           | 각 `aws_subnet.*.tags.Name`                                                                                  |
| **인터넷 게이트웨이 이름** (`wsc2026-logging-internet-gateway`)              | `aws_internet_gateway.main.tags.Name`                                                                        |
| **NAT 게이트웨이 이름** (`wsc2026-logging-natgateway-a/c`)                   | `aws_nat_gateway.nat_a/nat_c.tags.Name`                                                                      |
| **Public 라우팅 테이블 이름** (`wsc2026-logging-public-routing-table`)       | `aws_route_table.public.tags.Name`                                                                           |
| **Private 라우팅 테이블 이름** (`wsc2026-logging-private-routing-table-a/c`) | `aws_route_table.private_a/private_c.tags.Name`                                                              |
| **EKS 클러스터 이름** (`wsc2026-logging-cluster`)                            | `aws_eks_cluster.main.name` + 모든 IAM role 이름 + IRSA Condition                                            |
| **EKS Kubernetes 버전** (`1.35`)                                             | `aws_eks_cluster.main.version`                                                                               |
| **NodeGroup 이름** (`wsc2026-logging-node-group`)                            | `aws_eks_node_group.main.node_group_name`                                                                    |
| **NodeGroup 인스턴스 타입** (`t3.medium`)                                    | `aws_eks_node_group.main.instance_types`                                                                     |
| **NodeGroup min/max** (`2/4`)                                                | `aws_eks_node_group.main.scaling_config.min_size` / `max_size`                                             |
| **Worker 노드 Name 태그** (`wsc2026-logging-worker-node`)                    | `aws_eks_node_group.main.tags.Name`                                                                          |
| **ALB 이름** (`wsc2026-logging-alb`)                                         | `aws_lb.main.name`                                                                                           |
| **ALB 경로** (`/` → nginx, `/logging` → grafana)                         | `aws_lb_listener_rule.root.condition.path_pattern` + `aws_lb_listener_rule.logging.condition.path_pattern` |
| **Grafana 관리자 계정**                                                        | k8s Helm values에서 설정 (terraform 외부)                                                                      |
| **Grafana Pod 이름**                                                           | k8s 배포 manifest에서 설정 (terraform 외부)                                                                    |

---

## Module 3 — MSK (`module3/main.tf`)

| 바뀌는 값                                                                 | 수정 위치                                                                                                                                              |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **비번호**                                                          | `terraform apply -var="competitor_number=<비번호>"` 또는 `terraform.tfvars` 파일에 `competitor_number = "<값>"`                                  |
| **S3 버킷 이름 형식** (`wsc-msk-order-data-<비번호>-bucket`)      | `aws_s3_bucket.data.bucket`                                                                                                                          |
| **Region** (`ap-northeast-3`)                                     | `provider "aws"` → `region` + 모든 `availability_zone` 접두사 + `aws_lambda_function.consumer.environment.AWS_REGION_NAME`                    |
| **VPC CIDR** (`10.0.0.0/16`)                                      | `aws_vpc.main.cidr_block` + `aws_security_group.msk.ingress.cidr_blocks`                                                                           |
| **VPC 이름 태그** (`wsc-msk-vpc`)                                 | `aws_vpc.main.tags.Name`                                                                                                                             |
| **Public 서브넷 A CIDR/AZ** (`10.0.1.0/24`, `ap-northeast-3a`)  | `aws_subnet.public_a.cidr_block` / `availability_zone`                                                                                             |
| **Public 서브넷 C CIDR/AZ** (`10.0.2.0/24`, `ap-northeast-3c`)  | `aws_subnet.public_c.cidr_block` / `availability_zone`                                                                                             |
| **Private 서브넷 A CIDR/AZ** (`10.0.3.0/24`, `ap-northeast-3a`) | `aws_subnet.private_a.cidr_block` / `availability_zone`                                                                                            |
| **Private 서브넷 C CIDR/AZ** (`10.0.4.0/24`, `ap-northeast-3c`) | `aws_subnet.private_c.cidr_block` / `availability_zone`                                                                                            |
| **Bastion EC2 이름** (`wsc-bastion-ec2`)                          | `aws_instance.bastion.tags.Name`                                                                                                                     |
| **App EC2 이름** (`wsc-app-ec2`)                                  | `aws_instance.app.tags.Name`                                                                                                                         |
| **App EC2 인스턴스 타입** (`t3.medium`)                           | `aws_instance.app.instance_type`                                                                                                                     |
| **MSK 클러스터 이름** (`msk-order-cluster`)                       | `aws_msk_cluster.main.cluster_name`                                                                                                                  |
| **MSK 브로커 타입** (`kafka.m5.large`)                            | `aws_msk_cluster.main.broker_node_group_info.instance_type`                                                                                          |
| **MSK 브로커 수** (`2`)                                           | `aws_msk_cluster.main.number_of_broker_nodes`                                                                                                        |
| **MSK 스토리지** (`100GiB`)                                       | `aws_msk_cluster.main.broker_node_group_info.storage_info.ebs_storage_info.volume_size`                                                              |
| **MSK Kafka 버전** (`3.6.0`)                                      | `aws_msk_cluster.main.kafka_version`                                                                                                                 |
| **DynamoDB 테이블 이름** (`order-records`)                        | `aws_dynamodb_table.orders.name` + `aws_lambda_function.consumer.environment.DYNAMODB_TABLE_NAME`                                                  |
| **DynamoDB PK** (`orderId`)                                       | `aws_dynamodb_table.orders.hash_key` + `aws_dynamodb_table.orders.attribute[0]` + `module3/lambda.py` 의 `order_id = order.get("orderId")`     |
| **DynamoDB SK** (`timestamp`)                                     | `aws_dynamodb_table.orders.range_key` + `aws_dynamodb_table.orders.attribute[1]` + `module3/lambda.py` 의 `timestamp = order.get("timestamp")` |
| **Lambda 함수 이름** (`msk-order-consumer`)                       | `aws_lambda_function.consumer.function_name`                                                                                                         |
| **Lambda 런타임** (`python3.12`)                                  | `aws_lambda_function.consumer.runtime`                                                                                                               |
| **Lambda 메모리** (`256MB`)                                       | `aws_lambda_function.consumer.memory_size`                                                                                                           |
| **Lambda 타임아웃** (`60초`)                                      | `aws_lambda_function.consumer.timeout`                                                                                                               |
| **MSK 트리거 토픽** (`order-events`)                              | `aws_lambda_event_source_mapping.msk.topics`                                                                                                         |
| **MSK 트리거 배치 크기** (`100`)                                  | `aws_lambda_event_source_mapping.msk.batch_size`                                                                                                     |
| **MSK 시작 위치** (`TRIM_HORIZON`)                                | `aws_lambda_event_source_mapping.msk.starting_position`                                                                                              |

### MSK 토픽 생성 (terraform 외부 — App EC2에서 수동 실행)

```bash
# MSK 부트스트랩 브로커 확인
CLUSTER_ARN=$(aws kafka list-clusters --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text)
BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN --query BootstrapBrokerString --output text)

# 토픽 생성
kafka_2.13-3.5.1/bin/kafka-topics.sh --create --bootstrap-server $BOOTSTRAP \
  --topic order-events --partitions 3 --replication-factor 2
kafka_2.13-3.5.1/bin/kafka-topics.sh --create --bootstrap-server $BOOTSTRAP \
  --topic order-events-dlq --partitions 1 --replication-factor 2
```

---

## Module 4 — REST API (`module4/main.tf`, `module4/lambda.py`)

| 바뀌는 값                                                               | 수정 위치                                                                                                                                       |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Region** (`ap-southeast-1`)                                   | `provider "aws"` → `region`                                                                                                                |
| **Lambda 함수 이름** (`wsc2026-worldschool-management`)         | `aws_lambda_function.main.function_name`                                                                                                      |
| **Lambda Layer 이름** (`wsc2026-worldschool-env-layer`)         | `aws_lambda_layer_version.env_layer.layer_name`                                                                                               |
| **DynamoDB 테이블 이름** (`wsc2026-worldschool-table`)          | `aws_dynamodb_table.main.name` + `null_resource.layer_build` 의 `Set-Content` 값 (`tableName=...`) + `module4/layer/python/.env` 파일 |
| **DynamoDB PK** (`admission_year`, 타입 N)                      | `aws_dynamodb_table.main.hash_key` + `aws_dynamodb_table.main.attribute` + `module4/lambda.py` 의 Key 조회 부분                           |
| **DynamoDB SK** (`student_name`, 타입 S)                        | `aws_dynamodb_table.main.range_key` + `aws_dynamodb_table.main.attribute` + `module4/lambda.py` 의 Key 조회 부분                          |
| **API Gateway 이름** (`wsc2026-worldschool-api`)                | `aws_api_gateway_rest_api.main.name`                                                                                                          |
| **API Gateway Stage 이름** (`wsc2026-worldschool-api-stage`)    | `aws_api_gateway_stage.main.stage_name`                                                                                                       |
| **GET 필수 파라미터 이름** (`admission_year`, `student_name`) | `module4/lambda.py` 의 `queryStringParameters.get(...)` 부분                                                                                |
| **POST 필수 필드 이름** (`admission_year`, `student_name`)    | `module4/lambda.py` 의 `body.get(...)` 부분                                                                                                 |
| **입력값 검증 조건** (4자리 숫자 등)                              | `module4/lambda.py` 의 `isinstance(...) and len(str(...)) == 4` 부분                                                                        |

---

## module3 비번호 입력

`competitor_number` 에 기본값이 없으므로 `terraform apply` 시 자동으로 물어봅니다:

```
var.competitor_number
  Enter a value: 01      ← 본인 비번호
```

물어보는 게 싫으면 직접 전달:

```bash
terraform apply -var="competitor_number=01"
```

> PowerShell에서 `echo ... > terraform.tfvars` 는 UTF-16으로 저장되어 깨지므로 쓰지 말 것.
> 굳이 파일로 만들려면: `Set-Content -Path terraform.tfvars -Value 'competitor_number = "01"' -Encoding utf8`

---

## 주요 변경 빈도 순위 (대회 30% 수정 기준)

1. **이름/태그** — 클러스터명, 리소스명, 태그 → 해당 `name` / `tags.Name` 값만 변경
2. **CIDR / 서브넷** — VPC CIDR, 서브넷 CIDR → `cidr_block` 값 변경 (MSK SG ingress의 VPC CIDR도 같이 변경)
3. **인스턴스 타입** — NodeGroup, EC2, MSK 브로커 → `instance_type` / `instance_types` 값 변경
4. **스케일링 값** — min/max/desired → `scaling_config` 값 변경
5. **Lambda 설정** — 런타임, 메모리, 타임아웃 → `runtime` / `memory_size` / `timeout` 값 변경
6. **Region 변경** — `provider "aws".region` + AZ 접두사 + Lambda 환경변수 일괄 변경
