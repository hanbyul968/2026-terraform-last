# 2026 전국기능경기대회 클라우드컴퓨팅 - 제2과제 (06번) 실행 가이드

제2과제 "Small Challenge" 는 서로 **독립된 4개의 모듈**로 구성됩니다.
각 모듈은 별도의 Terraform 루트 디렉터리이며, **서로 다른 리전 / 서로 다른 state** 를 가집니다.
모듈 간 의존성은 없으므로 순서와 무관하게 각각 배포·삭제할 수 있습니다.

| 모듈 | 요구사항 | 리전 | 핵심 서비스 | 배포 방식 |
|------|----------|------|-------------|-----------|
| **module1** | 1) NoSQL | `ap-southeast-1` | DynamoDB, Streams, Lambda, EC2(Flask) | Terraform 단독 |
| **module2** | 2) CDN Function | `us-east-1` | S3(OAC), CloudFront, CF Functions, KeyValueStore | Terraform 단독 |
| **module3** | 3) EKS Scaling | `ap-northeast-2` | EKS, SQS, KEDA, Karpenter, IRSA | Terraform + kubectl |
| **module4** | 4) Container Logging (O11y) | `ap-northeast-1` | EKS, ALB, OTel Collector, Loki, Grafana | Terraform + `setup.sh` |

> ⚠️ 모든 이름·태그·변수는 **대소문자를 구분**합니다. 문제지에 명시된 리소스 이름을 그대로 사용하세요.
> ⚠️ 과제 종료 전 모든 부하 주입을 중지하고, module3 은 **Pod 1개 / Node 1대** 상태로 되돌려야 합니다.

---

## ⚡ 대회 30% 변경 시 수정 포인트 가이드

> 과제는 최대 30% 변경될 수 있습니다. 아래 표를 보고 바뀐 값에 해당하는 파일·위치를 즉시 수정하세요.

---

### Module 1 — NoSQL (`module1/main.tf`)

| 변경 항목 | 수정 파일 | 수정 위치 (리소스/속성) | 기본값 |
|-----------|-----------|------------------------|--------|
| **리전** | `module1/main.tf` | `provider "aws" { region = ... }` 및 `user_data` 내 `export AWS_REGION=...` | `ap-southeast-1` |
| **Reservation Table 이름** | `module1/main.tf` | `aws_dynamodb_table.reservation { name = ... }` | `bigbae-nosql-reservation-table` |
| **Reservation Table PK / SK 타입** | `module1/main.tf` | `attribute { name = "train_id" type = "S" }` / `attribute { name = "seat_id" type = "S" }` | `train_id(S)` / `seat_id(S)` |
| **DynamoDB Stream 뷰 타입** | `module1/main.tf` | `aws_dynamodb_table.reservation { stream_view_type = ... }` | `NEW_AND_OLD_IMAGES` |
| **GSI 이름** | `module1/main.tf` | `global_secondary_index { name = ... }` | `gsi-user-reservations` |
| **GSI PK / SK** | `module1/main.tf` | `global_secondary_index { hash_key = ... range_key = ... }` | `user_id` / `reserved_at` |
| **GSI Projection** | `module1/main.tf` | `global_secondary_index { projection_type = ... }` | `ALL` |
| **Audit Table 이름** | `module1/main.tf` | `aws_dynamodb_table.audit { name = ... }` | `bigbae-nosql-audit-table` |
| **Audit Table PK** | `module1/main.tf` | `aws_dynamodb_table.audit { hash_key = ... }` + `attribute { name = ... }` | `event_id(S)` |
| **Lambda 함수 이름** | `module1/main.tf` | `aws_lambda_function.audit { function_name = ... }` | `bigbae-nosql-reservation-audit` |
| **Lambda 런타임** | `module1/main.tf` | `aws_lambda_function.audit { runtime = ... }` | `python3.13` |
| **Lambda 타임아웃** | `module1/main.tf` | `aws_lambda_function.audit { timeout = ... }` | `30` |
| **EC2 인스턴스 이름 태그** | `module1/main.tf` | `aws_instance.app { tags = { Name = ... } }` | `bigbae-nosql-app-ec2` |
| **EC2 앱 포트** | `module1/main.tf` | `aws_security_group.app { ingress { from_port/to_port = ... } }` 및 `user_data` 내 `nohup python3.11 app.py &` 직전의 포트 설정 | `8080` |
| **EC2 환경변수 TABLE_NAME** | `module1/main.tf` | `user_data` 내 `export TABLE_NAME=...` | `bigbae-nosql-reservation-table` |
| **EC2 환경변수 GSI_NAME** | `module1/main.tf` | `user_data` 내 `export GSI_NAME=...` | `gsi-user-reservations` |
| **VPC CIDR** | `module1/main.tf` | `aws_vpc.main { cidr_block = ... }` | `10.0.0.0/16` |
| **서브넷 CIDR** | `module1/main.tf` | `aws_subnet.public { cidr_block = ... }` | `10.0.1.0/24` |
| **가용 영역** | `module1/main.tf` | `aws_subnet.public { availability_zone = ... }` | `ap-southeast-1a` |
| **Lambda 코드** | `module1/lambda.py` | 파일 전체 (terraform이 zip 후 배포) | 제공 파일 |
| **Flask 앱 코드** | `module1/app.py` | 파일 전체 (user_data에서 EC2에 복사) | 제공 파일 |

---

### Module 2 — CDN Function (`module2/main.tf`)

| 변경 항목 | 수정 파일 | 수정 위치 (리소스/속성) | 기본값 |
|-----------|-----------|------------------------|--------|
| **리전** | `module2/main.tf` | `provider "aws" { region = ... }` | `us-east-1` |
| **S3 버킷 이름 패턴** | `module2/main.tf` | `locals { bucket_name = "skillsphone-landing-ab-${local.account_id}" }` | `skillsphone-landing-ab-<ACCOUNT_ID>` |
| **index_a.html S3 경로** | `module2/main.tf` | `aws_s3_object.index_a { key = ... }` | `version-a/index.html` |
| **index_b.html S3 경로** | `module2/main.tf` | `aws_s3_object.index_b { key = ... }` | `version-b/index.html` |
| **index_a.html 내용** | `module2/index_a.html` | 파일 전체 | 제공 파일 |
| **index_b.html 내용** | `module2/index_b.html` | 파일 전체 | 제공 파일 |
| **KVS 이름** | `module2/main.tf` | `aws_cloudfront_key_value_store.ab_config { name = ... }` | `skillsphone-cdn-ab-config` |
| **KVS weight 값** | `module2/main.tf` | `aws_cloudfrontkeyvaluestore_key.weight { value = ... }` | `0.3` |
| **KVS version_a 경로** | `module2/main.tf` | `aws_cloudfrontkeyvaluestore_key.version_a { value = ... }` | `/version-a/index.html` |
| **KVS version_b 경로** | `module2/main.tf` | `aws_cloudfrontkeyvaluestore_key.version_b { value = ... }` | `/version-b/index.html` |
| **viewer-request 함수 이름** | `module2/main.tf` | `aws_cloudfront_function.viewer_request { name = ... }` | `skillsphone-cdn-ab-req-fn` |
| **viewer-response 함수 이름** | `module2/main.tf` | `aws_cloudfront_function.viewer_response { name = ... }` | `skillsphone-cdn-ab-res-fn` |
| **viewer-request 함수 코드** | `module2/cf_req_fn.js` | 파일 전체 | 제공 파일 |
| **viewer-response 함수 코드** | `module2/cf_res_fn.js` | 파일 전체 | 제공 파일 |
| **Cache Policy 이름** | `module2/main.tf` | `aws_cloudfront_cache_policy.ab { name = ... }` | `skillsphone-cdn-ab-cache-policy` |
| **Cache Policy TTL (Min/Default/Max)** | `module2/main.tf` | `aws_cloudfront_cache_policy.ab { min_ttl / default_ttl / max_ttl = ... }` | `0 / 300 / 3600` |
| **Cache Policy 쿠키 whitelist 키** | `module2/main.tf` | `cookies { items = ["x-sp-ab"] }` | `x-sp-ab` |
| **Distribution 이름(Comment)** | `module2/main.tf` | `aws_cloudfront_distribution.ab { comment = ... }` 및 `tags = { Name = ... }` | `skillsphone-cdn-ab-distribution` |
| **A/B 쿠키 이름** | `module2/cf_req_fn.js` , `module2/cf_res_fn.js` , `module2/main.tf` | JS 코드 내 `x-sp-ab` 문자열 + Cache Policy whitelist | `x-sp-ab` |

---

### Module 3 — EKS Scaling (`module3/main.tf`, `module3/k8s-*.yaml`)

| 변경 항목 | 수정 파일 | 수정 위치 | 기본값 |
|-----------|-----------|-----------|--------|
| **리전** | `module3/main.tf` | `provider "aws" { region = ... }` + `k8s-app.yaml` 내 `AWS_REGION` env | `ap-northeast-2` |
| **SQS Queue 이름** | `module3/main.tf` | `aws_sqs_queue.order { name = ... }` | `skm-order-queue` |
| **EKS Cluster 이름** | `module3/main.tf` | `aws_eks_cluster.main { name = ... }` (+ 서브넷 태그 `kubernetes.io/cluster/<NAME>`) | `skm-eks-cluster` |
| **EKS 버전** | `module3/main.tf` | `aws_eks_cluster.main { version = ... }` | `1.35` |
| **Addon NodeGroup 이름** | `module3/main.tf` | `aws_eks_node_group.addon { node_group_name = ... }` | `skm-cluster-addon-ng` |
| **Addon NodeGroup 노드 태그** | `module3/main.tf` | `aws_launch_template.addon_ng` 내 `tag_specifications { tags = { Name = ... } }` | `skm-cluster-addon-ng-node` |
| **Addon NodeGroup 인스턴스 타입** | `module3/main.tf` | `aws_eks_node_group.addon { instance_types = [...] }` | `t3.medium` |
| **Addon NodeGroup Desired/Min/Max** | `module3/main.tf` | `aws_eks_node_group.addon { scaling_config { desired/min/max_size = ... } }` | `1 / 1 / 1` |
| **App Deployment 이름** | `module3/k8s-app.yaml` | `metadata.name:` | `order-processor` |
| **App 초기 Replica 수** | `module3/k8s-app.yaml` | `spec.replicas:` | `1` |
| **App CPU/Memory Requests** | `module3/k8s-app.yaml` | `resources.requests.cpu` / `resources.requests.memory` | `500m` / `512Mi` |
| **App Namespace** | `module3/k8s-app.yaml` | `metadata.namespace:` (+ `k8s-keda.yaml`) | `skillsmkt` |
| **App 포트** | `module3/k8s-app.yaml` | `containerPort:` | `8080` |
| **PROCESSING_TIME 환경변수** | `module3/k8s-app.yaml` | `env: - name: PROCESSING_TIME value:` | `3` |
| **ScaledObject 이름** | `module3/k8s-keda.yaml` | `metadata.name:` | `order-scaler` |
| **ScaledObject Min/Max Replica** | `module3/k8s-keda.yaml` | `minReplicaCount:` / `maxReplicaCount:` | `1` / `5` |
| **KEDA queueLength (Pod당 메시지 수)** | `module3/k8s-keda.yaml` | `triggers[0].metadata.queueLength:` | `5` |
| **Karpenter NodePool 이름** | `module3/k8s-karpenter.yaml` | `metadata.name:` (+ `k8s-app.yaml` nodeSelector) | `skm-app-nodepool` |
| **Karpenter NodeClass 이름** | `module3/k8s-karpenter.yaml` | `EC2NodeClass metadata.name:` | `skm-app-nodeclass` |
| **Karpenter 허용 인스턴스 타입** | `module3/k8s-karpenter.yaml` | `requirements: - key: node.kubernetes.io/instance-type values: [...]` | `t3.small, t3.medium` |
| **Karpenter Consolidation 대기** | `module3/k8s-karpenter.yaml` | `disruption.consolidateAfter:` | `60s` |
| **App 코드** | `module3/app/app.py` | 파일 전체 | 제공 파일 |
| **VPC CIDR** | `module3/main.tf` | `aws_vpc.main { cidr_block = ... }` | `10.0.0.0/16` |
| **서브넷 CIDR (pub_a/pub_b)** | `module3/main.tf` | `aws_subnet.pub_a/pub_b { cidr_block = ... }` | `10.0.1.0/24` / `10.0.2.0/24` |

---

### Module 4 — Container Logging (`module4/main.tf`, `module4/manifest/setup.sh`)

| 변경 항목 | 수정 파일 | 수정 위치 | 기본값 |
|-----------|-----------|-----------|--------|
| **리전** | `module4/main.tf` + `module4/manifest/setup.sh` | `provider "aws" { region = ... }` + `REGION=` 변수 | `ap-northeast-1` |
| **EKS Cluster 이름** | `module4/main.tf` + `module4/manifest/setup.sh` | `aws_eks_cluster.main { name = ... }` + `CLUSTER=` 변수 | `o11y-cluster` |
| **EKS 버전** | `module4/main.tf` | `aws_eks_cluster.main { version = ... }` | `1.35` |
| **NodeGroup 인스턴스 타입** | `module4/main.tf` | `aws_eks_node_group.main { instance_types = [...] }` | `t3.medium` |
| **NodeGroup Desired/Min/Max** | `module4/main.tf` | `aws_eks_node_group.main { scaling_config { ... } }` | `2 / 2 / 2` |
| **App Deployment 이름** | `module4/manifest/setup.sh` | `kind: Deployment` → `metadata.name:` | `log-generator` |
| **App 초기 Replica** | `module4/manifest/setup.sh` | `spec.replicas:` | `2` |
| **App Namespace** | `module4/manifest/setup.sh` | `metadata.namespace:` | `o11y` |
| **App 포트** | `module4/manifest/setup.sh` | `containerPort:` | `8080` |
| **App ALB 이름** | `module4/main.tf` | `aws_lb.app { name = ... }` | `o11y-app-alb` |
| **App TG 이름** | `module4/main.tf` | `aws_lb_target_group.app { name = ... }` | `o11y-app-tg` |
| **App TG 포트** | `module4/main.tf` | `aws_lb_target_group.app { port = ... }` | `8080` |
| **Grafana ALB 이름** | `module4/main.tf` | `aws_lb.grafana { name = ... }` | `o11y-grafana-alb` |
| **Grafana TG 이름** | `module4/main.tf` | `aws_lb_target_group.grafana { name = ... }` | `o11y-grafana-tg` |
| **Grafana Deployment 이름** | `module4/manifest/setup.sh` | `helm upgrade --install o11y-grafana ...` (릴리스 이름) | `o11y-grafana` |
| **Grafana Admin ID** | `module4/manifest/setup.sh` | `--set adminUser="skills${number}"` | `skills<선수등번호>` |
| **Grafana Admin PW** | `module4/manifest/setup.sh` | `--set adminPassword="GoodJob!Skills${number}^^"` | `GoodJob!Skills<선수등번호>^^` |
| **Loki 릴리스/서비스 이름** | `module4/manifest/setup.sh` | `helm upgrade --install o11y-loki ...` (릴리스 이름) + OTel config endpoint URL | `o11y-loki` |
| **OTel DaemonSet 이름** | `module4/manifest/setup.sh` | `kind: DaemonSet` → `metadata.name:` | `o11y-otel` |
| **OTel 로그 수집 경로** | `module4/manifest/setup.sh` | `filelog.include:` | `/var/log/pods/*/*/*.log` |
| **Grafana 대시보드 이름** | `module4/manifest/setup.sh` | `"title":"Log Overview"` | `Log Overview` |
| **대시보드 LogQL namespace** | `module4/manifest/setup.sh` | `{k8s_namespace_name="o11y"}` | `o11y` |
| **VPC CIDR** | `module4/main.tf` | `aws_vpc.main { cidr_block = ... }` | `10.0.0.0/16` |
| **서브넷 CIDR (pub_a/pub_c)** | `module4/main.tf` | `aws_subnet.pub_a/pub_c { cidr_block = ... }` | `10.0.1.0/24` / `10.0.2.0/24` |
| **가용 영역** | `module4/main.tf` | `aws_subnet.pub_a { availability_zone = "ap-northeast-1a" }` + `pub_c { ... "ap-northeast-1c" }` | `1a` / `1c` |
| **App 코드** | `module4/manifest/app.py` | 파일 전체 | 제공 파일 |
| **선수 등번호** | `terraform apply` 명령어 | `-var="competitor_number=<번호>"` + `number=<번호>` 환경변수 | 당일 배정 |

---

## 실행법

### 사전 준비

필요 도구: `terraform`, `aws cli`, `kubectl`, `helm`, `docker`, `jq`

```powershell
# Windows (winget)
winget install Hashicorp.Terraform Amazon.AWSCLI Kubernetes.kubectl Helm.Helm Docker.DockerDesktop jqlang.jq
```

```bash
# Linux (Amazon Linux 2023)
sudo yum install -y yum-utils && sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform docker jq
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o a.zip && unzip a.zip && sudo ./aws/install
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sudo systemctl enable --now docker && sudo usermod -aG docker $USER
```

```bash
aws configure              # Access Key / Secret / Region 입력
aws sts get-caller-identity
```

---

### module1 — NoSQL (`ap-southeast-1`)

```bash
cd module1
terraform init
terraform apply
```

```bash
# 검증 (EC2 기동까지 1~2분 소요)
PUB_IP=$(aws ec2 describe-instances --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=bigbae-nosql-app-ec2" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].PublicIpAddress" --output text)

curl http://$PUB_IP:8080/healthcheck

# 예약 → 200, 중복 예약 → 409
curl -XPOST http://$PUB_IP:8080/reserve \
  -H 'Content-Type: application/json' \
  -d '{"train_id":"KTX-001","seat_id":"A1","user_id":"u1"}'
curl -XPOST http://$PUB_IP:8080/reserve \
  -H 'Content-Type: application/json' \
  -d '{"train_id":"KTX-001","seat_id":"A1","user_id":"u2"}'   # 409 확인

# 취소, 좌석 조회, 내 예약 조회
curl -XPOST http://$PUB_IP:8080/cancel \
  -H 'Content-Type: application/json' \
  -d '{"train_id":"KTX-001","seat_id":"A1","user_id":"u1"}'
curl http://$PUB_IP:8080/seats/KTX-001
curl http://$PUB_IP:8080/my-bookings/u1
```

---

### module2 — CDN Function (`us-east-1`)

```bash
cd module2
terraform init
terraform apply
```

```bash
# 검증 (Distribution 전파 수 분 소요)
DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='skillsphone-cdn-ab-distribution'].DomainName" \
  --output text)

# 쿠키 없음 → weight(0.3) 기반 a/b 랜덤 할당 + Set-Cookie 헤더 확인
curl -sI https://$DOMAIN/ | grep -i set-cookie

# 쿠키 고정 → 동일 버전 반환 확인
curl -s -b "x-sp-ab=a" https://$DOMAIN/ | grep -i "version\|title"
curl -s -b "x-sp-ab=b" https://$DOMAIN/ | grep -i "version\|title"
```

---

### module3 — EKS Scaling (`ap-northeast-2`)

> Docker가 동작하는 환경에서 실행 (CloudShell 불가)

```bash
cd module3
terraform init
terraform apply      # ECR 빌드/푸시 + EKS + KEDA + Karpenter + 워크로드 자동 배포
```

```bash
# kubeconfig 연결
aws eks update-kubeconfig --name skm-eks-cluster --region ap-northeast-2

# 상태 확인
kubectl get pods -n skillsmkt
kubectl get scaledobject -n skillsmkt
kubectl get nodes

# Scale-out 테스트: SQS에 메시지 다량 주입 → Pod 최대 5개, 노드 부족 시 Karpenter가 추가
QUEUE_URL=$(aws sqs get-queue-url --queue-name skm-order-queue --region ap-northeast-2 --query QueueUrl --output text)
for i in $(seq 1 30); do
  aws sqs send-message --queue-url $QUEUE_URL --message-body "order-$i" --region ap-northeast-2
done
kubectl get pods -n skillsmkt -w    # Pod 늘어나는 것 확인

# Scale-in 확인: 메시지 소진 후 Pod → 1개, 노드 → 1대 (약 2분 대기)
kubectl get nodes -l karpenter.sh/nodepool=skm-app-nodepool -w
```

> ⚠️ 과제 종료 전 부하 중지 → Pod 1개 / Node 1대 상태로 반드시 복귀

---

### module4 — Container Logging (`ap-northeast-1`)

> Docker가 동작하는 환경에서 실행

**Step 1: 인프라 배포**

```bash
cd module4
terraform init
terraform apply -var="competitor_number=<선수등번호>"
```

**Step 2: setup.sh 실행**

```bash
# Linux / WSL
cd module4/manifest
number=<선수등번호> bash setup.sh

# Windows (PowerShell → Git Bash)
cd module4/manifest
$env:number = "<선수등번호>"
& "C:\Program Files\Git\bin\bash.exe" ./setup.sh
```

```bash
# 검증
kubectl get pods -n o11y          # log-generator 2개 Running
kubectl get pods -n monitoring    # o11y-loki, o11y-grafana, o11y-otel DaemonSet

# App 로그 생성
APP_ALB=$(aws elbv2 describe-load-balancers --names o11y-app-alb --region ap-northeast-1 \
  --query 'LoadBalancers[0].DNSName' --output text)
curl "http://$APP_ALB/healthz"
curl "http://$APP_ALB/log?level=info&count=10"
curl "http://$APP_ALB/log?level=warn&count=10"
curl "http://$APP_ALB/log?level=error&count=10"

# Grafana 접속
GRAFANA_ALB=$(aws elbv2 describe-load-balancers --names o11y-grafana-alb --region ap-northeast-1 \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "http://$GRAFANA_ALB   →   skills<번호> / GoodJob!Skills<번호>^^"

# 대시보드 확인
curl -s -u "skills<번호>:GoodJob!Skills<번호>^^" \
  "http://$GRAFANA_ALB/api/dashboards/uid/log-overview" | jq -r '.dashboard.title'
```

---

### 리소스 정리 (Teardown)

```bash
# module3
cd module3 && terraform destroy

# module4 (Helm 먼저 제거 후 destroy)
cd ../module4
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall o11y-loki o11y-grafana -n monitoring 2>/dev/null || true
terraform destroy -var="competitor_number=<선수등번호>"

# module1 / module2
cd ../module1 && terraform destroy
cd ../module2 && terraform destroy
```
