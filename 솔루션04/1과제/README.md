# 제1과제 (인천 v2) — AWS 콘솔 풀이 가이드 (처음부터 끝까지)

Terraform 없이 **AWS Management Console** 클릭만으로 제1과제를 구성하는 순서다.
모든 리소스는 **서울(ap-northeast-2)**. CloudFront/WAF 만 **N. Virginia(us-east-1)**.
값(이름/CIDR/태그)은 대소문자까지 정확히 입력한다.

> 진행 원칙
> - 리전을 **ap-northeast-2** 로 고정하고 시작(우상단 리전 선택).
> - 이름 태그는 표에 적힌 그대로. 채점 스크립트가 `Name` 태그로 리소스를 찾는다.
> - 순서대로 하지 않으면 의존성 때문에 막힌다. 아래 목차 순서 권장.

## 목차 / 배포 순서
1. KMS (CMK) — 다른 리소스가 참조하므로 먼저
2. VPC / 서브넷 / 라우팅 / 엔드포인트
3. Bastion (EC2)
4. DynamoDB
5. S3 + 정적파일 업로드
6. ECR + 이미지 빌드/푸시
7. EKS 클러스터
8. EKS 노드그룹 (app / addon / monitoring)
9. Bastion 에서 kubectl / helm 준비
10. 쿠버네티스 앱 (Namespace/ConfigMap/Deployment/SA/StorageClass)
11. AWS Load Balancer Controller + app-lb(내부) + Lambda
12. Lambda (조회 API)
13. CloudFront (VPC Origin) + S3 오리진
14. WAF
15. Fluent Bit (로깅)
16. Prometheus / Grafana (모니터링) + addon-lb
17. 마무리(EKS 퍼블릭 차단) & 자체 점검

참고값 (Reference)
- VPC: `wsc-vpc` `10.0.0.0/16`
- 서브넷(이름 / CIDR / AZ / 라우팅)
  - `wsc-public-a` 10.0.0.0/24 / 2a / `wsc-public-rtb` (IGW)
  - `wsc-public-c` 10.0.1.0/24 / 2c / `wsc-public-rtb` (IGW)
  - `wsc-private-a` 10.0.2.0/24 / 2a / `wsc-private-a-rtb` (NAT)
  - `wsc-private-c` 10.0.3.0/24 / 2c / `wsc-private-c-rtb` (NAT)
  - `wsc-workload-a` 10.0.4.0/24 / 2a / `wsc-workload-a-rtb` (라우팅 없음)
  - `wsc-workload-c` 10.0.5.0/24 / 2c / `wsc-workload-c-rtb` (라우팅 없음)
- SSH 비밀번호: `Skill53##`
- 클러스터 도메인: `wsc.local`

---

## 1. KMS (Customer Managed Key)

DynamoDB/S3/ECR/EKS/EBS/CloudWatch Logs 암호화에 공용으로 쓴다.

1. 콘솔 → **KMS** → *Customer managed keys* → **Create key**
2. Key type: **Symmetric**, Key usage: **Encrypt and decrypt** → Next
3. Alias: `wsc-key` → Next
4. Key administrators: 본인(관리자) 선택 → Next
5. Key usage permissions: 본인 계정/역할 선택 → Next → **Finish**
6. 생성된 키의 **ARN** 을 메모(뒤에서 계속 사용).
7. (로그/서비스 암호화용) 키 정책에 아래 두 조항 추가 → *Key policies* → *Edit*:
   - CloudWatch Logs 가 쓸 수 있게 `logs.ap-northeast-2.amazonaws.com` 에 Encrypt/Decrypt/GenerateDataKey 허용 (EncryptionContext 조건: `kms:EncryptionContext:aws:logs:arn` ArnLike `arn:aws:logs:ap-northeast-2:<ACCOUNT_ID>:log-group:*`)
   - EBS/S3/ECR/DynamoDB `ViaService` 허용(계정 조건 포함)

> 팁: 정책을 손대기 번거로우면 처음엔 기본 정책으로 두고, 로그그룹/EBS 암호화 단계에서
> `AccessDenied` 가 나면 그때 해당 서비스 principal 을 추가한다.

---

## 2. VPC / 서브넷 / 라우팅 / 엔드포인트

### 2.1 VPC
1. **VPC** → *Your VPCs* → **Create VPC** → *VPC only*
2. Name tag `wsc-vpc`, IPv4 CIDR `10.0.0.0/16` → Create
3. 생성 후 *Actions → Edit VPC settings* 에서 **Enable DNS hostnames**, **Enable DNS resolution** 체크

### 2.2 서브넷 6개
*Subnets → Create subnet* → VPC `wsc-vpc` 선택 후 위 참고표대로 6개 생성.
- public 2개: 생성 후 *Actions → Edit subnet settings → Enable auto-assign public IPv4* 체크
- workload 2개: *Edit subnet settings → Resource-based name (hostname type) = Resource name*, *Enable DNS A record* 체크
  (노드 hostname 이 `i-xxxx.ap-northeast-2.compute.internal` 이 되게 함 — 채점 6-2)

### 2.3 IGW / NAT
1. *Internet Gateways → Create* `wsc-igw` → *Actions → Attach to VPC* `wsc-vpc`
2. *Elastic IPs → Allocate* 2개 (`wsc-nat-a-eip`, `wsc-nat-c-eip`)
3. *NAT Gateways → Create*:
   - `wsc-nat-a`: subnet `wsc-public-a`, EIP `wsc-nat-a-eip`
   - `wsc-nat-c`: subnet `wsc-public-c`, EIP `wsc-nat-c-eip`

### 2.4 라우팅 테이블 (채점 1-1-C 매우 민감)
*Route Tables → Create* (VPC `wsc-vpc`) 로 5개 생성 후 라우팅/연결:

| 라우팅테이블 | 라우팅 | 연결 서브넷 |
|---|---|---|
| `wsc-public-rtb` | `0.0.0.0/0 → wsc-igw` | wsc-public-a, wsc-public-c |
| `wsc-private-a-rtb` | `0.0.0.0/0 → wsc-nat-a` | wsc-private-a |
| `wsc-private-c-rtb` | `0.0.0.0/0 → wsc-nat-c` | wsc-private-c |
| `wsc-workload-a-rtb` | **없음(local 만)** | wsc-workload-a |
| `wsc-workload-c-rtb` | **없음(local 만)** | wsc-workload-c |

> ⚠️ workload RTB 에는 IGW/NAT/엔드포인트 어떤 라우팅도 넣지 않는다.
> (채점: workload RTB 의 igw-/nat-/vpce- 경로 수 = 0)

### 2.5 VPC 엔드포인트
- **Gateway** (S3, DynamoDB): *Endpoints → Create* → 서비스 `com.amazonaws.ap-northeast-2.s3`(Gateway), `...dynamodb`(Gateway) → **연결 라우팅테이블은 `wsc-private-a-rtb`, `wsc-private-c-rtb` 만** 체크 (workload 제외!)
- **Interface** (노드가 인터넷 없이 AWS 사용): 아래 서비스들을 각각 Interface 로 생성. Subnet `wsc-workload-a`, `wsc-workload-c`, *Enable DNS name* 체크, 전용 SG(`wsc-vpce-sg`, 인바운드 443 from 10.0.0.0/16)
  - `ecr.api`, `ecr.dkr`, `sts`, `logs`, `ec2`, `eks`, `eks-auth`, `elasticloadbalancing`, `autoscaling`, `ssm`, `ssmmessages`, `ec2messages`, `monitoring`, `s3`(Interface — ECR 레이어용)

---

## 3. Bastion (EC2)

1. **EC2 → Security Groups → Create** `wsc-bastion-sg` (VPC wsc-vpc)
   - Inbound: SSH(22) from `0.0.0.0/0`
   - Outbound: All
2. **IAM → Roles → Create role** → EC2 → 정책 **AdministratorAccess** → 이름 `wsc-bastion-role`
3. **EC2 → Instances → Launch instances**
   - Name: `wsc-bastion`
   - AMI: **Amazon Linux 2023**, Type: **t3.medium**
   - Key pair: 없어도 됨(패스워드 접속 사용)
   - Network: VPC `wsc-vpc`, Subnet `wsc-public-a`, **Auto-assign public IP: Enable**, SG `wsc-bastion-sg`
   - IAM instance profile: `wsc-bastion-role`
   - **Advanced → User data** 에 아래 입력:
     ```bash
     #!/bin/bash
     set -eux
     echo "ec2-user:Skill53##" | chpasswd
     mkdir -p /etc/ssh/sshd_config.d
     printf 'PasswordAuthentication yes\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/50-wsc.conf
     systemctl restart sshd
     dnf -y install jq iputils tar gzip git unzip
     curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/a.zip
     cd /tmp && unzip -q a.zip && ./aws/install --update
     curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
     chmod +x /usr/local/bin/kubectl
     curl -fsSL https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz | tar xz -C /usr/local/bin
     dnf -y install sshpass || true
     aws configure set default.region ap-northeast-2
     ```
4. Launch 후 **Elastic IP** 할당 → *Associate* 로 bastion 에 고정(`wsc-bastion-eip`). (재시작 IP 고정, 채점)
5. 접속 확인: `ssh ec2-user@<EIP>` / 비번 `Skill53##`

---

## 4. DynamoDB

1. **DynamoDB → Tables → Create table**
   - Table name: `wsc-table`
   - Partition key: `client_id` (String)
2. *Customize settings* → *Encryption at rest* → **Stored in your account, owned and managed by you** → KMS key `alias/wsc-key`
3. Create.

> username/email/concert_name 는 비키 속성이라 정의 불필요(항목 넣을 때 자동).

---

## 5. S3 + 정적파일

1. **S3 → Create bucket**
   - Name: `wsc-static-<ACCOUNT_ID>` (본인 12자리 계정ID)
   - Block all public access: **ON**(체크 유지)
   - Default encryption: **SSE-KMS**, key `alias/wsc-key`, Bucket Key: Enable
2. 버킷 → **Create folder** `static`
3. `static/` 안에 배포파일 업로드: `index.html`, `main.jpeg`
   (업로드 시 *Properties → Server-side encryption → Specify KMS key* `alias/wsc-key`)
   - 결과 키: `static/index.html`, `static/main.jpeg` (채점 3-1-A)
4. 버킷 정책은 CloudFront 만든 뒤(13절)에 OAC 허용으로 추가한다.

---

## 6. ECR + 이미지 빌드

### 6.1 리포지토리
1. **ECR → Repositories → Create**
   - Name: `wsc-repo`
   - Tag immutability: **Disabled(MUTABLE)** (채점 5-1-A)
   - Scan on push: **Enable**
   - Encryption: **KMS**, key `alias/wsc-key`
2. 노드가 인터넷 없이 addon 이미지를 받게 **Pull through cache** 규칙 추가:
   *ECR → Pull through cache → Create* → prefix `ecr-public` upstream `public.ecr.aws`, prefix `quay` upstream `quay.io`

### 6.2 book 이미지 빌드/푸시 (Bastion 또는 docker 되는 머신)
Bastion 엔 docker 가 없으니, **CloudShell** 또는 docker 설치된 EC2에서:
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2
REG=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
# Dockerfile (scratch + upx + static curl, 8MB 이하 + 취약점0 + curl 내장)
cat > Dockerfile <<'EOF'
FROM alpine:3.21 AS prep
WORKDIR /out
COPY book /out/app
RUN apk add --no-cache upx binutils ca-certificates curl \
 && strip /out/app || true && upx -9 /out/app || true \
 && curl -fsSL -o /tmp/curl https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64 \
 && chmod +x /tmp/curl && upx -9 /tmp/curl || true && cp /tmp/curl /out/curl
FROM scratch
COPY --from=prep /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=prep /out/app /app
COPY --from=prep /out/curl /usr/bin/curl
ENTRYPOINT ["/app"]
EOF
# book 바이너리를 같은 폴더에 두고
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 --provenance=false -t $REG/wsc-repo:v1.0.0 .
docker push $REG/wsc-repo:v1.0.0
aws ecr describe-images --repository-name wsc-repo --query 'imageDetails[].imageSizeInBytes'  # 8MB 이하 확인
```

---

## 7. EKS 클러스터

1. **IAM → Roles** `wsc-eks-cluster-role` (EKS - Cluster, 정책 `AmazonEKSClusterPolicy`)
2. **EKS → Add cluster → Create**
   - Name: `wsc-eks-cluster`, Version **1.35**, Role: `wsc-eks-cluster-role`
   - **Secrets encryption: Enable** → KMS `alias/wsc-key`
   - Networking: VPC `wsc-vpc`, Subnets **wsc-workload-a, wsc-workload-c**, cluster SG `wsc-eks-cluster-sg`(10.0.0.0/16 all 인바운드)
   - Cluster endpoint access: 생성 단계에선 **Public and private**(뒤에서 Public 끔)
   - Control plane logging: **모두 Enable**(api, audit, authenticator, controllerManager, scheduler)
3. 생성(10~15분).

---

## 8. EKS 노드그룹 (app / addon / monitoring)

세 그룹 모두 동일 방식, 값만 다르다.

| 노드그룹 | Name | Label | Instance Name 태그 |
|---|---|---|---|
| app | `wsc-app-ng` | `type=app` | `wsc-app-node` |
| addon | `wsc-addon-ng` | `type=addon` | `wsc-addon-node` |
| monitoring | `wsc-monitoring-ng` | `type=monitoring` | `wsc-monitoring-node` |

공통:
1. **IAM Role** (그룹별 별도) EC2 신뢰, 정책: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore` + 인라인(KMS Decrypt, ECR pull-through)
2. **Launch Template** (EC2 → Launch templates → Create), 그룹별:
   - Storage: EBS `/dev/xvda` 30GiB gp3 **Encrypted = yes, KMS = alias/wsc-key** (채점 6-3)
   - Advanced → **Metadata** → app 그룹만 *Response hop limit = 1* (Pod IMDS 차단, 채점 6-5)
   - Advanced → **User data**: nodeadm MIME (도메인 wsc.local + SSH 비번):
     ```
     MIME-Version: 1.0
     Content-Type: multipart/mixed; boundary="//"
     --//
     Content-Type: application/node.eks.aws
     apiVersion: node.eks.aws/v1alpha1
     kind: NodeConfig
     spec:
       cluster:
         name: wsc-eks-cluster
       kubelet:
         config:
           clusterDomain: wsc.local
         flags:
           - "--node-labels=type=app"      # 그룹별로 app/addon/monitoring
     --//
     Content-Type: text/x-shellscript
     #!/bin/bash
     echo "ec2-user:Skill53##" | chpasswd
     mkdir -p /etc/ssh/sshd_config.d
     printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-wsc.conf
     systemctl restart sshd
     --//--
     ```
     (관리형 노드그룹 + Launch Template 조합에선 name/endpoint/CA/cidr 는 EKS 가 자동 주입되므로 위처럼 name 만 둬도 된다)
3. **EKS → Compute → Add node group**:
   - Name, Role, AMI type **Amazon Linux 2023(x86_64)**, Instance **t3.medium**
   - Desired 2 / Min 2 / Max 3, Subnet **wsc-workload-a, wsc-workload-c**
   - Launch template: 위에서 만든 그룹 LT, Kubernetes labels `type=<group>`

> 노드가 Ready 안되면: Interface 엔드포인트(§2.5)와 노드 role 의 ECR/KMS 권한 확인.

---

## 9. Bastion 에서 kubectl / helm 준비

Bastion 접속 후:
```bash
aws eks update-kubeconfig --region ap-northeast-2 --name wsc-eks-cluster
kubectl get nodes          # 6개 Ready 확인
# EKS 접근권한이 없다면 콘솔 EKS → Access → Create access entry 로
#   Bastion role(wsc-bastion-role) 에 AmazonEKSClusterAdminPolicy 부여
# helm 설치
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
CoreDNS 를 `wsc.local` 로: (콘솔 EKS → Add-ons → CoreDNS 설정에서 corefile 의
`kubernetes cluster.local` → `kubernetes wsc.local` 로 수정, nodeSelector type=addon) 또는
`kubectl -n kube-system edit configmap coredns` 로 `cluster.local` 을 `wsc.local` 로 변경 후
`kubectl -n kube-system rollout restart deploy coredns` (채점 6-6).

---

## 10. 쿠버네티스 앱

Bastion 에서 매니페스트 적용:
```bash
kubectl create namespace wsc
kubectl create namespace logging
kubectl create namespace monitoring

# ServiceAccount (Pod Identity 로 DynamoDB 접근)
kubectl -n wsc create serviceaccount book-sa

# ConfigMap (환경변수 중앙관리, 채점 6-7-B)
kubectl -n wsc create configmap wsc-config \
  --from-literal=AWS_REGION=ap-northeast-2 --from-literal=TABLE_NAME=wsc-table
```
Pod Identity: 콘솔 **EKS → Access → Pod Identity associations → Create**
- namespace `wsc`, SA `book-sa`, Role: DynamoDB(PutItem/GetItem/Query/Scan)+KMS 권한 role
- 사전에 **eks-pod-identity-agent** 애드온 설치.

Deployment/Service (`wsc-deploy`, container `wsc-cnt`, replicas 2, app 노드):
```yaml
# book.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: wsc-deploy, namespace: wsc, labels: { app: wsc-deploy } }
spec:
  replicas: 2
  selector: { matchLabels: { app: wsc-deploy } }
  template:
    metadata: { labels: { app: wsc-deploy } }
    spec:
      serviceAccountName: book-sa
      nodeSelector: { type: app }
      containers:
        - name: wsc-cnt
          image: <ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/wsc-repo:v1.0.0
          ports: [{ containerPort: 8080 }]
          envFrom: [{ configMapRef: { name: wsc-config } }]
          readinessProbe: { httpGet: { path: /health, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: wsc-deploy, namespace: wsc }
spec:
  selector: { app: wsc-deploy }
  ports: [{ port: 80, targetPort: 8080 }]
```
```bash
kubectl apply -f book.yaml
```
StorageClass `wsc-sc` (EBS CSI, CMK) — 사전에 **aws-ebs-csi-driver** 애드온 + Pod Identity:
```yaml
# sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: wsc-sc }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: <CMK ARN>
```

---

## 11. AWS Load Balancer Controller + app-lb (내부) + Lambda 연결

### 11.1 LB Controller
1. IAM Policy `wsc-AWSLoadBalancerControllerIAMPolicy`
   ([공식 JSON](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json)) → Role + Pod Identity(ns kube-system, SA aws-load-balancer-controller)
2. ```bash
   helm repo add eks https://aws.github.io/eks-charts && helm repo update
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
     --set clusterName=wsc-eks-cluster --set region=ap-northeast-2 --set vpcId=<VPC_ID> \
     --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
     --set nodeSelector.type=addon
   ```

### 11.2 app-lb (내부, 콘솔 EC2 → Load Balancers)
- **Create → Application Load Balancer** `wsc-app-lb`
  - Scheme: **Internal**, Subnets: **wsc-private-a, wsc-private-c**
  - SG: `wsc-app-lb-sg` (지금은 인바운드 비워두고, 13절 CloudFront VPC Origin 만든 뒤 그 SG 만 80 허용 → 채점 7-1-B 직접접근 timeout)
  - Listener HTTP:80 → default action **Return fixed response 404 "Contents Not Found"**
- **Target group** `wsc-book-tg` (IP, HTTP 8080, health `/health`) — book Pod 용
- **Target group** `wsc-lambda-tg` (Lambda) — 12절 Lambda 등록
- Listener 규칙:
  - `POST /v1/book` → `wsc-book-tg`
  - `GET /v1/book` → `wsc-lambda-tg`
- book Pod 를 TG 에 붙이기(TargetGroupBinding):
  ```yaml
  apiVersion: elbv2.k8s.aws/v1beta1
  kind: TargetGroupBinding
  metadata: { name: wsc-book-tgb, namespace: wsc }
  spec:
    serviceRef: { name: wsc-deploy, port: 80 }
    targetType: ip
    targetGroupARN: <wsc-book-tg ARN>
  ```

---

## 12. Lambda (조회 API)

1. **IAM Role** `wsc-lambda-role`: `AWSLambdaVPCAccessExecutionRole` + DynamoDB(Query/GetItem/Scan)+KMS Decrypt
2. **Lambda → Create function** `wsc-get-table-function`
   - Runtime **Python 3.14**, Role 위 role
   - VPC: `wsc-vpc`, Subnets **wsc-private-a, wsc-private-c**(채점 4-1-B False), SG `wsc-lambda-sg`(egress all)
   - Env: `TABLE_NAME=wsc-table`
   - 코드(`lambda_function.handler`):
     ```python
     import json, os, boto3
     from boto3.dynamodb.conditions import Key
     t = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
     def r(s,b): return {"statusCode":s,"statusDescription":str(s),"isBase64Encoded":False,
       "headers":{"Content-Type":"application/json"},"body":json.dumps(b)}
     def handler(e,c):
         cid=(e.get("queryStringParameters") or {}).get("client_id")
         if not cid: return r(400,{"msg":"client_id is required"})
         it=t.query(KeyConditionExpression=Key("client_id").eq(cid)).get("Items",[])
         if not it: return r(404,{"msg":"Item not found"})
         i=it[0]
         return r(200,{"username":i.get("username"),"booking_id":i.get("booking_id"),
           "email":i.get("email"),"client_id":i.get("client_id"),"concert_name":i.get("concert_name")})
     ```
3. `wsc-lambda-tg` 에 이 Lambda 를 target 으로 등록(ELB → TG → Register targets → Lambda).
   (ELB 가 Lambda 를 호출하도록 자동으로 resource-based permission 이 붙는다)

---

## 13. CloudFront (VPC Origin) + WAF

> 리전 상관없지만 CloudFront/WAF 는 글로벌/us-east-1.

### 13.1 VPC Origin
**CloudFront → VPC origins → Create** → `wsc-app-lb` 선택, HTTP 80.

### 13.2 Distribution `wsc-cdn`
1. **CloudFront → Create distribution**
2. Origin 1 (S3): 버킷 `wsc-static-<ID>` 선택, **Origin access: OAC**(새로 생성), **Origin path `/static`**
3. Origin 2 (ALB): **VPC origin** 위에서 만든 `wsc-app-lb` 선택
4. Default behavior → Origin = S3, **Viewer protocol: Redirect HTTP to HTTPS**, Cache policy **CachingOptimized**
5. Behavior 추가: Path `/v1/*` → Origin = ALB, Cache policy **CachingDisabled**, Origin request policy **AllViewer**(쿼리스트링 전달)
6. Settings: **Price class = All**, **IPv6 = Off**, WAF 는 14절에서 연결
7. Create → **Distribution domain name** 메모.
8. **S3 버킷 정책**: 콘솔이 제안하는 OAC 정책을 복사해 S3 버킷 정책에 붙여넣기(CloudFront `s3:GetObject` 허용).
9. **app-lb-sg 인바운드**: VPC Origin 생성 시 만들어진 `CloudFront-VPCOrigins-Service-SG` 를 소스로 80 허용 → app-lb 직접접근 차단(7-1-B).

---

## 14. WAF (`wsc-waf`, CLOUDFRONT scope)

1. 리전을 **Global(CloudFront)** 로. **WAF → Create web ACL**
   - Name `wsc-waf`, Resource type **CloudFront**, 연결 리소스: `wsc-cdn`
2. Rule 추가(Rule builder):
   - Rule 1: If **all** — (Inspect: **Body**, Match: **contains** `admin`, Text transform **Lowercase**) AND (Inspect: **HTTP method**, contains `POST`) → Action **Block**
   - Rule 2: 동일하게 `sysop` → Block
3. Default action **Allow** → Create.

(채점 9-1 은 rule 의 SearchString 을 디코드해 admin/sysop 을 확인한다)

---

## 15. Fluent Bit (로깅)

1. **CloudWatch Logs → Log groups → Create** `/wsc/pod/log`, **KMS = CMK** (채점 12-1-A)
2. IAM Role + Pod Identity(ns logging, SA fluent-bit): logs:CreateLogStream/PutLogEvents + KMS
3. ```bash
   kubectl -n logging create serviceaccount fluent-bit
   helm repo add eks https://aws.github.io/eks-charts
   helm install fluent-bit eks/aws-for-fluent-bit -n logging \
     --set fullnameOverride=fluent-bit \
     --set serviceAccount.create=false --set serviceAccount.name=fluent-bit \
     --set cloudWatchLogs.region=ap-northeast-2 \
     --set cloudWatchLogs.logGroupName=/wsc/pod/log \
     --set cloudWatchLogs.autoCreateGroup=false
   ```
4. `/health` 로그 제외: values 에 grep 필터(Exclude `log /health`) 추가(채점 12-1-B).
   DaemonSet 이름은 반드시 `fluent-bit`.

---

## 16. Prometheus / Grafana + addon-lb

1. PVC 2개 먼저(이름 정확): `wsc-prometheus-pvc`, `wsc-grafana-pvc` (storageClassName `wsc-sc`)
2. Prometheus (helm `prometheus-community/prometheus`):
   - nodeSelector `type=monitoring`, server `prefixURL=/prometheus`, existingClaim `wsc-prometheus-pvc`
   - node-exporter(모든 노드), kube-state-metrics(monitoring)
3. Grafana (helm `grafana/grafana`):
   - nodeSelector `type=monitoring`, existingClaim `wsc-grafana-pvc`
   - admin / `Skill53##`
   - `serve_from_sub_path=true`, root_url `.../grafana`
   - Datasource Prometheus URL: `http://prometheus-server.monitoring.svc.wsc.local/prometheus`
   - Dashboard `wsc-eks-dashboard` (아래 6패널)
4. **addon-lb** (Ingress, public): monitoring ns 에 Ingress 생성
   - annotation: scheme `internet-facing`, `load-balancer-name: wsc-addon-lb`, subnets `wsc-public-a,wsc-public-c`
   - path `/grafana` → grafana svc:80, `/prometheus` → prometheus-server svc:80

Grafana 대시보드 6패널 (제목/타입/쿼리):
| 패널 | 타입 | PromQL |
|---|---|---|
| TOTAL_NODE_GROUP_COUNT | stat | `count(kube_node_info)` (=6) |
| APP_POD_COUNT | stat | `count(kube_pod_info{namespace="wsc"})` (=2) |
| NODE_GROUP_CPU_USAGE | timeseries | `sum by (instance)(rate(node_cpu_seconds_total{mode!="idle"}[5m]))` |
| NODE_GROUP_MEMORY_USAGE | timeseries | `sum by (instance)(node_memory_MemTotal_bytes-node_memory_MemAvailable_bytes)` |
| APP_POD_CPU_USAGE | bargauge | `sum by (pod)(rate(container_cpu_usage_seconds_total{namespace="wsc",pod=~"wsc-deploy.*",container!=""}[5m]))` |
| APP_POD_MEMORY_USAGE | bargauge | `sum by (pod)(container_memory_working_set_bytes{namespace="wsc",pod=~"wsc-deploy.*",container!=""})` |

---

## 17. 마무리 & 자체 점검

1. **EKS 퍼블릭 차단**: EKS → 클러스터 → *Networking → Manage endpoint access* →
   **Public 해제, Private 만 유지** (채점 6-1-A: Public False / Private True). 이후 채점은 Bastion 에서.
2. Bastion 에서 배포 채점 스크립트(`mark.sh`)를 `/home/ec2-user/marking/` 에 두고 실행하며 확인.
3. 빠른 자체 점검:
   ```bash
   CDN=<cloudfront-domain>
   curl -I https://$CDN/index.html                 # S3 Hit
   curl -i http://$CDN/index.html                  # 301 redirect
   curl -X POST https://$CDN/v1/book -d '{"client_id":"C001","username":"Alice","email":"a@b.com","concert_name":"S"}'  # booking_id
   curl https://$CDN/v1/book?client_id=C001         # 조회
   curl -o /dev/null -w "%{http_code}" -X POST https://$CDN/v1/book -d '{"username":"admin"...}'  # 403 (WAF)
   ```

> 콘솔 방식은 클릭이 많아 실수(태그 오타/서브넷 선택)가 잦다. 각 리소스 **Name 태그**와
> **서브넷/라우팅**을 참고표와 한 번씩 대조하고 넘어갈 것.
