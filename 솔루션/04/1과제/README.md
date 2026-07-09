# 🖥️ 제1과제 (인천 v2) — AWS 콘솔 풀이 가이드

> **Terraform 없이 AWS Management Console 클릭만으로** 제1과제를 처음부터 끝까지 구성하는 문서.
> 각 단계는 **① 입력값 표 → ② 클릭 순서 → ③ 채점 포인트 → ⚠️ 주의** 순서로 정리했다.

---

## 🧭 시작 전 3가지

| 항목 | 값 |
|---|---|
| 리전 (우상단 고정) | **ap-northeast-2 (서울)** — CloudFront/WAF 만 us-east-1 |
| 이름/태그 | 표에 적힌 **대소문자 그대로** (채점이 `Name` 태그로 찾음) |
| 순서 | 아래 체크리스트 **위에서 아래로** (의존성 있음) |

## ✅ 전체 진행 체크리스트

```
[ ] 1.  KMS (CMK)              alias/wsc-key
[ ] 2.  VPC / 서브넷6 / 라우팅5 / 엔드포인트
[ ] 3.  Bastion (EC2)          wsc-bastion  (EIP 고정)
[ ] 4.  DynamoDB               wsc-table
[ ] 5.  S3 + 정적파일           wsc-static-<ACCOUNT_ID>
[ ] 6.  ECR + 이미지            wsc-repo:v1.0.0  (<8MB)
[ ] 7.  EKS 클러스터            wsc-eks-cluster (1.35)
[ ] 8.  노드그룹 3개            app / addon / monitoring
[ ] 9.  Bastion kubectl + CoreDNS(wsc.local)
[ ] 10. 앱 배포                 wsc-deploy / wsc-cnt / wsc-config / wsc-sc
[ ] 11. LB Controller + app-lb(내부)
[ ] 12. Lambda                 wsc-get-table-function
[ ] 13. CloudFront             wsc-cdn (VPC Origin)
[ ] 14. WAF                    wsc-waf
[ ] 15. Fluent Bit             /wsc/pod/log
[ ] 16. Prometheus/Grafana + addon-lb
[ ] 17. 마무리 (EKS Public 차단) + 자체점검
```

## 📌 참고값 한눈에

<details>
<summary><b>서브넷 · 라우팅 표 (클릭)</b></summary>

| 서브넷 | CIDR | AZ | 라우팅테이블 | 라우팅 |
|---|---|---|---|---|
| `wsc-public-a` | 10.0.0.0/24 | 2a | `wsc-public-rtb` | 0.0.0.0/0 → IGW |
| `wsc-public-c` | 10.0.1.0/24 | 2c | `wsc-public-rtb` | 0.0.0.0/0 → IGW |
| `wsc-private-a` | 10.0.2.0/24 | 2a | `wsc-private-a-rtb` | 0.0.0.0/0 → NAT-a |
| `wsc-private-c` | 10.0.3.0/24 | 2c | `wsc-private-c-rtb` | 0.0.0.0/0 → NAT-c |
| `wsc-workload-a` | 10.0.4.0/24 | 2a | `wsc-workload-a-rtb` | **없음(local만)** |
| `wsc-workload-c` | 10.0.5.0/24 | 2c | `wsc-workload-c-rtb` | **없음(local만)** |

</details>

- VPC `wsc-vpc` = `10.0.0.0/16`  ·  SSH 비번 = `Skill53##`  ·  클러스터 도메인 = `wsc.local`

---

# 1. 🔐 KMS (Customer Managed Key)

DynamoDB/S3/ECR/EKS/EBS/CloudWatch Logs 암호화에 공용으로 쓰는 키.

**① 입력값**

| 항목 | 값 |
|---|---|
| Key type | Symmetric / Encrypt and decrypt |
| Alias | `wsc-key` |

**② 클릭 순서**
1. **KMS** → *Customer managed keys* → **Create key**
2. Symmetric → Next → Alias `wsc-key` → Next
3. Key administrators / usage permissions에 본인 역할 선택 → **Finish**
4. 생성된 키 **ARN 복사**해서 메모장에 저장 (이후 계속 붙여넣음)

**③ 채점 포인트** — 2-1-B, 3-1-B, 6-1-B, 12-1-A 등에서 `arn:aws:kms…` 확인

> ⚠️ 로그그룹/EBS 암호화에서 `AccessDenied` 나면, 키 정책(*Key policies → Edit*)에
> `logs.ap-northeast-2.amazonaws.com` 및 EBS/S3/ECR `ViaService` 허용 조항을 추가.

---

# 2. 🌐 VPC / 서브넷 / 라우팅 / 엔드포인트

## 2.1 VPC
1. **VPC** → *Create VPC* → **VPC only**
2. Name `wsc-vpc`, CIDR `10.0.0.0/16` → Create
3. *Actions → Edit VPC settings* → **Enable DNS hostnames** + **DNS resolution** 체크

## 2.2 서브넷 6개
*Subnets → Create subnet* → VPC `wsc-vpc` → 위 참고표대로 6개 생성 후:
- **public 2개** → *Edit subnet settings* → ✅ *Enable auto-assign public IPv4*
- **workload 2개** → *Edit subnet settings* → ✅ *Resource name* (hostname type) + *Enable DNS A record*
  → 노드 hostname이 `i-xxxx.ap-northeast-2.compute.internal` 이 됨 (**채점 6-2**)

## 2.3 IGW + NAT
1. *Internet Gateways* → Create `wsc-igw` → *Attach to VPC* `wsc-vpc`
2. *Elastic IPs* → Allocate 2개
3. *NAT Gateways* → Create 2개
   - `wsc-nat-a` : subnet `wsc-public-a`
   - `wsc-nat-c` : subnet `wsc-public-c`

## 2.4 라우팅 테이블 5개
*Route Tables → Create* (VPC `wsc-vpc`) 후 라우팅/연결:

| 라우팅테이블 | 라우팅 추가 | Subnet associations |
|---|---|---|
| `wsc-public-rtb` | 0.0.0.0/0 → `wsc-igw` | public-a, public-c |
| `wsc-private-a-rtb` | 0.0.0.0/0 → `wsc-nat-a` | private-a |
| `wsc-private-c-rtb` | 0.0.0.0/0 → `wsc-nat-c` | private-c |
| `wsc-workload-a-rtb` | ❌ 추가 안 함 | workload-a |
| `wsc-workload-c-rtb` | ❌ 추가 안 함 | workload-c |

> ⚠️ **workload RTB에는 어떤 라우팅도 넣지 않는다** (IGW/NAT/엔드포인트 전부 금지).
> 채점 1-1-C: workload RTB의 igw-/nat-/vpce- 경로 수 = **0**.

## 2.5 VPC 엔드포인트
- **Gateway (S3, DynamoDB)** — *Endpoints → Create*
  - 서비스: `…s3`(Gateway), `…dynamodb`(Gateway)
  - **연결 RTB: `wsc-private-a-rtb`, `wsc-private-c-rtb` 만** ✅ (workload 절대 제외!)
- **Interface (노드용, workload 서브넷)** — SG `wsc-vpce-sg`(인바운드 443 from 10.0.0.0/16), *Enable DNS name* ✅
  - `ecr.api` `ecr.dkr` `sts` `logs` `ec2` `eks` `eks-auth` `elasticloadbalancing` `autoscaling` `ssm` `ssmmessages` `ec2messages` `monitoring` `s3(Interface)`

**③ 채점 포인트** — 1-1-A(VPC CIDR), 1-1-B(서브넷 6개 순서), 1-1-C(라우팅 수)

---

# 3. 🖧 Bastion (EC2)

**① 입력값**

| 항목 | 값 |
|---|---|
| Name | `wsc-bastion` |
| AMI / Type | Amazon Linux 2023 / t3.medium |
| Subnet | `wsc-public-a` (public IP on) |
| SG | `wsc-bastion-sg` (인바운드 SSH 22 ← 0.0.0.0/0) |
| IAM Role | `wsc-bastion-role` (AdministratorAccess) |

**② 클릭 순서**
1. **EC2 → Security Groups** → `wsc-bastion-sg` (SSH 22 from 0.0.0.0/0)
2. **IAM → Roles** → EC2 신뢰 + `AdministratorAccess` → `wsc-bastion-role`
3. **EC2 → Launch instances** → 위 표대로. **Advanced → User data** 붙여넣기 ↓
4. Launch 후 **Elastic IP 할당 → Associate** (재시작 IP 고정)

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

**③ 채점 포인트** — Bastion 접속(비번 `Skill53##`), EIP 고정, SSH만 허용, Admin 권한

---

# 4. 🗄️ DynamoDB

**① 입력값**

| 항목 | 값 |
|---|---|
| Table name | `wsc-table` |
| Partition key | `client_id` (String) |
| Encryption | 본인 소유 KMS `alias/wsc-key` |

**② 클릭 순서**
1. **DynamoDB → Create table** → 이름/PK 입력
2. *Customize settings* → *Encryption at rest* → **Stored in your account** → `alias/wsc-key`

**③ 채점 포인트** — 2-1-A(`client_id S`), 2-1-B(KMS ARN)

---

# 5. 📦 S3 + 정적파일

**① 입력값**

| 항목 | 값 |
|---|---|
| Bucket | `wsc-static-<ACCOUNT_ID>` (12자리 계정ID) |
| Public access | 차단 유지(ON) |
| Encryption | SSE-KMS `alias/wsc-key` + Bucket Key |
| 업로드 경로 | `static/index.html`, `static/main.jpeg` |

**② 클릭 순서**
1. **S3 → Create bucket** → 위 표대로
2. 버킷 → **Create folder** `static`
3. `static/` 안에 `index.html`, `main.jpeg` 업로드
   (업로드 시 *Properties → SSE → Specify KMS key* `alias/wsc-key`)
4. 버킷 정책은 **13절(CloudFront)** 후 OAC 허용으로 추가

**③ 채점 포인트** — 3-1-A(키 2개), 3-1-B(버킷/객체 KMS)

---

# 6. 🐳 ECR + 이미지 빌드

## 6.1 리포지토리

| 항목 | 값 |
|---|---|
| Name | `wsc-repo` |
| Tag immutability | **MUTABLE (Disabled)** |
| Scan on push | Enable |
| Encryption | KMS `alias/wsc-key` |

- **ECR → Create repository** → 위 표대로
- **Pull through cache** 규칙 추가: prefix `ecr-public`→`public.ecr.aws`, `quay`→`quay.io`
  (노드가 인터넷 없이 addon 이미지 pull)

## 6.2 이미지 빌드/푸시 (CloudShell 또는 docker 되는 머신)

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-2; REG=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
# book 바이너리를 현재 폴더에 둔 뒤:
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
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 --provenance=false -t $REG/wsc-repo:v1.0.0 .
docker push $REG/wsc-repo:v1.0.0
aws ecr describe-images --repository-name wsc-repo --query 'imageDetails[].imageSizeInBytes'  # 8MB 이하?
```

**③ 채점 포인트** — 5-1-A(MUTABLE/scan/KMS), 5-2-A(<8MB), 5-2-B(취약점 0), 컨테이너 내 curl(6-5)

---

# 7. ☸️ EKS 클러스터

| 항목 | 값 |
|---|---|
| Name / Version | `wsc-eks-cluster` / **1.35** |
| Role | `wsc-eks-cluster-role` (`AmazonEKSClusterPolicy`) |
| Secrets encryption | Enable → `alias/wsc-key` |
| Subnets | **wsc-workload-a, wsc-workload-c** |
| Endpoint access | 지금은 **Public and private** (17절에서 Public 끔) |
| Control plane logging | **5개 모두 Enable** |

1. **IAM → Roles** `wsc-eks-cluster-role`
2. **EKS → Add cluster → Create** → 위 표대로 (생성 10~15분)

**③ 채점 포인트** — 6-1-A(버전/로그/endpoint), 6-1-B(KMS)

---

# 8. 🖥️ EKS 노드그룹 (app / addon / monitoring)

| 노드그룹 | Name | Label | Instance Name 태그 | IMDS hop |
|---|---|---|---|---|
| app | `wsc-app-ng` | `type=app` | `wsc-app-node` | **1** |
| addon | `wsc-addon-ng` | `type=addon` | `wsc-addon-node` | 2 |
| monitoring | `wsc-monitoring-ng` | `type=monitoring` | `wsc-monitoring-node` | 2 |

**공통 (그룹마다 반복)**
1. **IAM Role** (그룹별): `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`,
   `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore` + 인라인(KMS Decrypt / ECR pull-through)
2. **Launch Template** (EC2 → Launch templates):
   - Storage `/dev/xvda` 30GiB gp3 → **Encrypted ✅ / KMS `alias/wsc-key`** (채점 6-3)
   - Advanced → Metadata → **app 그룹만 Hop limit = 1** (채점 6-5)
   - Advanced → **User data** (nodeadm MIME, 도메인+SSH비번):
     ```
     MIME-Version: 1.0
     Content-Type: multipart/mixed; boundary="//"
     --//
     Content-Type: application/node.eks.aws
     apiVersion: node.eks.aws/v1alpha1
     kind: NodeConfig
     spec:
       cluster: { name: wsc-eks-cluster }
       kubelet:
         config: { clusterDomain: wsc.local }
         flags: ["--node-labels=type=app"]   # 그룹별 app/addon/monitoring
     --//
     Content-Type: text/x-shellscript
     #!/bin/bash
     echo "ec2-user:Skill53##" | chpasswd
     mkdir -p /etc/ssh/sshd_config.d
     printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-wsc.conf
     systemctl restart sshd
     --//--
     ```
3. **EKS → Compute → Add node group**: AMI **AL2023(x86_64)**, Instance **t3.medium**,
   Desired/Min 2 · Max 3, Subnet **workload-a/c**, Label `type=<group>`, 위 Launch template 지정

**③ 채점 포인트** — 6-2(hostname/type/instance-type), 6-3(볼륨암호화), 6-4(ping/curl), 6-5(app IMDS 차단)

> ⚠️ 노드가 Ready 안 되면 → §2.5 Interface 엔드포인트 + 노드 role ECR/KMS 권한 확인.

---

# 9. 🔧 Bastion에서 kubectl / CoreDNS

```bash
# Bastion 접속 후
aws eks update-kubeconfig --region ap-northeast-2 --name wsc-eks-cluster
kubectl get nodes            # 6개 Ready 확인
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```
- kubectl 권한 없으면 → 콘솔 **EKS → Access → Create access entry** 로
  `wsc-bastion-role` 에 `AmazonEKSClusterAdminPolicy` 부여.
- **CoreDNS 도메인 wsc.local** (채점 6-6):
  ```bash
  kubectl -n kube-system edit configmap coredns   # 'cluster.local' → 'wsc.local'
  kubectl -n kube-system rollout restart deploy coredns
  kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep 'kubernetes wsc.local'
  ```

---

# 10. 📦 쿠버네티스 앱 배포

```bash
kubectl create namespace wsc
kubectl create namespace logging
kubectl create namespace monitoring
kubectl -n wsc create serviceaccount book-sa
kubectl -n wsc create configmap wsc-config \
  --from-literal=AWS_REGION=ap-northeast-2 --from-literal=TABLE_NAME=wsc-table
```
- **Pod Identity** (앱→DynamoDB, 노드 IAM 미사용): 사전에 `eks-pod-identity-agent` 애드온 설치 →
  콘솔 **EKS → Access → Pod Identity associations → Create** (ns `wsc`, SA `book-sa`, DynamoDB+KMS role)
- **Deployment / Service** (`book.yaml`):
  ```yaml
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
- **StorageClass `wsc-sc`** (사전에 `aws-ebs-csi-driver` 애드온 + Pod Identity):
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata: { name: wsc-sc }
  provisioner: ebs.csi.aws.com
  volumeBindingMode: WaitForFirstConsumer
  parameters: { type: gp3, encrypted: "true", kmsKeyId: <CMK ARN> }
  ```

**③ 채점 포인트** — 6-7-A(replicas 2), 6-7-B(ConfigMap 참조), 6-7-C(SC 암호화)

---

# 11. ⚖️ LB Controller + app-lb(내부)

## 11.1 AWS Load Balancer Controller
```bash
# IAM policy: 공식 iam_policy.json 으로 wsc-AWSLoadBalancerControllerIAMPolicy 생성
# → Role + Pod Identity (ns kube-system, SA aws-load-balancer-controller)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=wsc-eks-cluster --set region=ap-northeast-2 --set vpcId=<VPC_ID> \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set nodeSelector.type=addon
```

## 11.2 app-lb (콘솔 EC2 → Load Balancers)

| 항목 | 값 |
|---|---|
| Name / Scheme | `wsc-app-lb` / **Internal** |
| Subnets | wsc-private-a, wsc-private-c |
| SG | `wsc-app-lb-sg` (인바운드는 13절 후 CloudFront SG만 80 허용) |
| Listener | HTTP:80 → default **404 "Contents Not Found"** |

- Target group `wsc-book-tg` (IP, HTTP 8080, health `/health`)
- Target group `wsc-lambda-tg` (Lambda, 12절 등록)
- Listener 규칙: `POST /v1/book`→book-tg · `GET /v1/book`→lambda-tg
- book Pod ↔ TG 바인딩:
  ```yaml
  apiVersion: elbv2.k8s.aws/v1beta1
  kind: TargetGroupBinding
  metadata: { name: wsc-book-tgb, namespace: wsc }
  spec:
    serviceRef: { name: wsc-deploy, port: 80 }
    targetType: ip
    targetGroupARN: <wsc-book-tg ARN>
  ```

**③ 채점 포인트** — 7-1-A(internal/private), 7-1-B(직접접근 timeout), 10-3(404)

---

# 12. λ Lambda (조회 API)

| 항목 | 값 |
|---|---|
| Name / Runtime | `wsc-get-table-function` / **Python 3.14** |
| VPC / Subnet | wsc-vpc / **wsc-private-a, wsc-private-c** |
| Env | `TABLE_NAME=wsc-table` |
| Role | VPC 실행 + DynamoDB(Query/Get/Scan) + KMS Decrypt |

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
- 생성 후 **ELB → wsc-lambda-tg → Register targets → Lambda** 로 등록

**③ 채점 포인트** — 4-1-A(python3.14), 4-1-B(private subnet), 10-2(조회), 404 메시지

---

# 13. 🌍 CloudFront (VPC Origin)

1. **CloudFront → VPC origins → Create** → `wsc-app-lb` 선택 (HTTP 80)
2. **Create distribution** `wsc-cdn`:

| 설정 | 값 |
|---|---|
| Origin 1 (S3) | 버킷 `wsc-static-<ID>`, **OAC 새로 생성**, **Origin path `/static`** |
| Origin 2 (ALB) | **VPC origin** = `wsc-app-lb` |
| Default behavior | Origin=S3, **Redirect HTTP→HTTPS**, Cache=CachingOptimized |
| Behavior `/v1/*` | Origin=ALB, Cache=**CachingDisabled**, OriginRequest=**AllViewer** |
| Settings | **Price class = All**, **IPv6 = Off** |

3. 생성 후 **도메인 이름 메모**
4. **S3 버킷 정책**: 콘솔 제안 OAC 정책 복사 → S3 버킷 정책에 붙여넣기
5. **app-lb-sg 인바운드**: `CloudFront-VPCOrigins-Service-SG` 소스로 80 허용 (→ 7-1-B timeout)

**③ 채점 포인트** — 8-1(PriceClass_All/IPv6 False), 8-2(캐시 Hit / 301 redirect)

---

# 14. 🛡️ WAF (`wsc-waf`)

1. 리전 **Global (CloudFront)** → **WAF → Create web ACL**
   - Name `wsc-waf`, Resource type **CloudFront**, 연결 `wsc-cdn`
2. Rule (Rule builder):
   - **Rule1**: (Body **contains** `admin`, transform **Lowercase**) **AND** (HTTP method contains `POST`) → **Block**
   - **Rule2**: 동일하게 `sysop` → **Block**
3. Default action **Allow**

**③ 채점 포인트** — 9-1(admin/sysop 차단), 10-3-B(403)

---

# 15. 📝 Fluent Bit (로깅)

1. **CloudWatch Logs → Create log group** `/wsc/pod/log` → **KMS `alias/wsc-key`**
2. IAM Role + Pod Identity (ns `logging`, SA `fluent-bit`): logs 쓰기 + KMS
3. 설치:
   ```bash
   kubectl -n logging create serviceaccount fluent-bit
   helm install fluent-bit eks/aws-for-fluent-bit -n logging \
     --set fullnameOverride=fluent-bit \
     --set serviceAccount.create=false --set serviceAccount.name=fluent-bit \
     --set cloudWatchLogs.region=ap-northeast-2 \
     --set cloudWatchLogs.logGroupName=/wsc/pod/log \
     --set cloudWatchLogs.autoCreateGroup=false
   ```
4. `/health` 제외 grep 필터(Exclude `log /health`) 추가. **DaemonSet 이름은 반드시 `fluent-bit`**.

**③ 채점 포인트** — 12-1-A(KMS), 12-1-B(/health 제외), 12-1-C(/v1/book 수집)

---

# 16. 📊 Prometheus / Grafana + addon-lb

1. **PVC 2개** (이름 정확): `wsc-prometheus-pvc`, `wsc-grafana-pvc` (SC `wsc-sc`)
2. **Prometheus** (helm `prometheus-community/prometheus`):
   - nodeSelector `type=monitoring`, server `prefixURL=/prometheus`, existingClaim `wsc-prometheus-pvc`
3. **Grafana** (helm `grafana/grafana`):
   - nodeSelector `type=monitoring`, existingClaim `wsc-grafana-pvc`, admin `Skill53##`
   - `serve_from_sub_path=true`, root_url `.../grafana`
   - Datasource: `http://prometheus-server.monitoring.svc.wsc.local/prometheus`
   - Dashboard `wsc-eks-dashboard` (아래 6패널)
4. **addon-lb** (Ingress, ns monitoring):
   - scheme `internet-facing`, `load-balancer-name: wsc-addon-lb`, subnets `wsc-public-a,wsc-public-c`
   - `/grafana`→grafana:80, `/prometheus`→prometheus-server:80

**대시보드 6패널**

| 패널 | 타입 | PromQL | 기대값 |
|---|---|---|---|
| TOTAL_NODE_GROUP_COUNT | stat | `count(kube_node_info)` | 6 |
| APP_POD_COUNT | stat | `count(kube_pod_info{namespace="wsc"})` | 2 |
| NODE_GROUP_CPU_USAGE | timeseries | `sum by(instance)(rate(node_cpu_seconds_total{mode!="idle"}[5m]))` | 6 |
| NODE_GROUP_MEMORY_USAGE | timeseries | `sum by(instance)(node_memory_MemTotal_bytes-node_memory_MemAvailable_bytes)` | 6 |
| APP_POD_CPU_USAGE | bargauge | `sum by(pod)(rate(container_cpu_usage_seconds_total{namespace="wsc",pod=~"wsc-deploy.*",container!=""}[5m]))` | 2 |
| APP_POD_MEMORY_USAGE | bargauge | `sum by(pod)(container_memory_working_set_bytes{namespace="wsc",pod=~"wsc-deploy.*",container!=""})` | 2 |

**③ 채점 포인트** — 11-1(healthy/datasource/패널 6), 11-2(패널별 값)

---

# 17. 🏁 마무리 & 자체 점검

1. **EKS Public 차단**: EKS → 클러스터 → *Networking → Manage endpoint access* →
   **Public 해제 / Private 유지** (채점 6-1-A: Public False / Private True). 이후 채점은 Bastion에서.
2. **mark.sh** 를 Bastion `/home/ec2-user/marking/` 에 두고 실행.
3. 빠른 자체 점검:
   ```bash
   CDN=<cloudfront-domain>
   curl -I  https://$CDN/index.html                 # x-cache: Hit
   curl -i  http://$CDN/index.html                  # 301
   curl -X POST https://$CDN/v1/book -H 'Content-Type: application/json' \
     -d '{"client_id":"C001","username":"Alice","email":"a@b.com","concert_name":"S"}'   # booking_id
   curl "https://$CDN/v1/book?client_id=C001"        # 조회 JSON
   curl -o /dev/null -w "%{http_code}" -X POST https://$CDN/v1/book \
     -H 'Content-Type: application/json' -d '{"username":"admin"}'   # 403
   ```

> ✅ 마지막 점검: 각 리소스의 **Name 태그**와 **서브넷/라우팅**을 참고표와 한 번씩 대조.
> 콘솔은 클릭이 많아 오타·서브넷 오선택이 가장 흔한 감점 원인이다.
