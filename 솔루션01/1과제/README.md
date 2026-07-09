# 2026 클라우드컴퓨팅 1과제 — AWS 콘솔 수동 구축 가이드 (처음부터 끝까지)

과제지_v3 / 채점기준표_v2 기준. **테라폼 없이 AWS 콘솔 + CloudShell** 로 전체를 구축하는 순서.
리전은 **전부 서울(ap-northeast-2)**. `<비번호>` 는 본인 비번호로 치환.

> 콘솔로만 안 되는 부분(EKS 노드그룹=eksctl, 앱 배포=kubectl, Prometheus=helm)은 **CloudShell** 명령으로 진행한다. 과제지도 노드그룹은 eksctl 을 요구한다.

## 전체 순서 요약
1. KMS 키 → 2. VPC/서브넷/RT/IGW/NAT → 3. Flow Logs → 4. S3+CloudFront → 5. ECR(+이미지 push) → 6. DynamoDB(+Backup) → 7. EKS 클러스터 → 8. 노드그룹(app/addon) → 9. 앱 배포(book) → 10. ALB(LB Controller) → 11. Prometheus → 12. 마무리(private 전환·EKS admin)

체크 명령은 각 단계 끝 `✅확인` 참고(채점 스크립트와 동일 쿼리).

---

## 0. 사전 준비
- 콘솔 로그인, 우측 상단 리전 = **서울**.
- CloudShell 아이콘(콘솔 상단) 열기 → `aws sts get-caller-identity` 로 계정 확인.
- 배포파일(book, index.html, main.jpeg, Dockerfile)을 CloudShell 로 업로드하거나, S3 경유로 가져온다.

---

## 1. KMS 고객관리형 키 (CMK)
FlowLogs·S3·ECR·EKS 암호화에 **공용**으로 쓴다.
1. **KMS 콘솔 → 고객 관리형 키 → 키 생성**
   - 키 유형: **대칭**, 사용: **암호화/복호화**
   - 별칭: `wsc-2026-key`
   - 키 관리 권한/사용 권한: 본인(관리자) 지정 → 생성
2. 생성 후 **키 정책(JSON)** 편집 → 아래 사용 주체 허용 추가(콘솔에서 서비스가 쓰도록):
   - CloudWatch Logs(`logs.ap-northeast-2.amazonaws.com`), S3, ECR, EKS 가 `kms:Encrypt/Decrypt/GenerateDataKey*/DescribeKey/CreateGrant` 하도록.
   - CloudWatch Logs 는 `kms:EncryptionContext:aws:logs:arn` 조건으로 로그그룹 ARN 허용.
3. 생성된 **키 ARN** 메모(이후 계속 사용).

✅ 다른 리소스들이 이 키 ARN 을 동일하게 참조해야 채점에서 같은 key 로 보인다.

---

## 2. VPC / 서브넷 / 라우팅
**VPC 콘솔 → VPC 생성 → "VPC 등만"** 으로 하나씩 만들거나 "VPC 등"으로 한 번에. 값 표:

| 리소스 | 이름 | CIDR / 설정 |
|--------|------|-------------|
| VPC | `wsc-vpc` | `10.0.0.0/16`, DNS 호스트네임/확인 **활성화** |
| Subnet | `wsc-pub-sn-a` | `10.0.0.0/24`, AZ **2a**, 퍼블릭IP 자동할당 ON |
| Subnet | `wsc-pub-sn-b` | `10.0.1.0/24`, AZ **2b**, 퍼블릭IP 자동할당 ON |
| Subnet | `wsc-priv-sn-a` | `10.0.2.0/24`, AZ **2a** |
| Subnet | `wsc-priv-sn-b` | `10.0.3.0/24`, AZ **2b** |

1. **인터넷 게이트웨이** `wsc-igw` 생성 → `wsc-vpc` 에 연결.
2. **NAT 게이트웨이** 2개(HA):
   - `wsc-nat-a`: 서브넷 `wsc-pub-sn-a`, 새 EIP 할당
   - `wsc-nat-b`: 서브넷 `wsc-pub-sn-b`, 새 EIP 할당
3. **라우팅 테이블**:
   - `wsc-pub-rt` → 경로 `0.0.0.0/0` = `wsc-igw`; 연결 서브넷 = pub-sn-a, pub-sn-b
   - `wsc-priv-rt-a` → 경로 `0.0.0.0/0` = `wsc-nat-a`; 연결 = priv-sn-a
   - `wsc-priv-rt-b` → 경로 `0.0.0.0/0` = `wsc-nat-b`; 연결 = priv-sn-b
4. **EKS 서브넷 태그**(로드밸런서 자동배치용): pub 서브넷 2개에 `kubernetes.io/role/elb=1`, priv 서브넷 2개에 `kubernetes.io/role/internal-elb=1`, 4개 모두 `kubernetes.io/cluster/wsc-eks-cluster=shared`.

✅ `aws ec2 describe-subnets` 로 이름·CIDR 4개 일치 확인.

---

## 3. VPC Flow Logs → CloudWatch (KMS, 12필드)
1. **CloudWatch → 로그 그룹 생성**: 이름 `/aws/vpc/flowlogs`, **KMS 키 ARN = wsc-2026-key** 지정, 보존 7일.
2. **IAM 역할** `wsc-vpc-flowlogs-role` 생성: 신뢰주체 `vpc-flow-logs.amazonaws.com`, 정책에 `logs:CreateLogStream/PutLogEvents/CreateLogGroup/Describe*` 허용.
3. **VPC 콘솔 → wsc-vpc → 흐름 로그 생성**:
   - 필터 **ALL**, 대상 **CloudWatch Logs**, 로그그룹 `/aws/vpc/flowlogs`, 역할 위 IAM.
   - **사용자 지정 형식** 선택 후 아래 12필드 **순서대로**:
     ```
     ${account-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${start} ${end} ${action} ${vpc-id} ${subnet-id} ${region}
     ```
   - 집계 간격 1분.

✅ `aws ec2 describe-flow-logs` 로 Format/Destination(cloud-watch-logs)/Status=ACTIVE, 로그그룹 KMS 확인.

---

## 4. S3 + CloudFront (정적 호스팅)
### 4-1. S3
1. **S3 → 버킷 생성**: `wsc-2026-bucket-<비번호>`, 리전 서울, **모든 퍼블릭 액세스 차단 ON**.
2. **기본 암호화**: **DSSE-KMS**(이중 계층) + 키 `wsc-2026-key`, **버킷 키 사용 ON**.
3. `index.html`, `main.jpeg` 업로드.

### 4-2. CloudFront Function
**CloudFront → 함수 → 생성**: 이름 `wsc-2026-functions`, 런타임 **cloudfront-js-2.0**. 코드:
```js
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === '/index' || uri === '/index/') request.uri = '/index.html';
  else if (uri === '/main' || uri === '/main/') request.uri = '/main.jpeg';
  return request;
}
```
→ **게시(Publish)**.

### 4-3. Distribution
**CloudFront → 배포 생성**:
- 원본: 위 S3 버킷, **Origin access control(OAC)** 새로 생성해 사용(퍼블릭 차단 유지).
- 기본 캐시 동작 → **함수 연결: Viewer request = wsc-2026-functions**.
- 뷰어 프로토콜: Redirect HTTP→HTTPS. 이름/설명 `wsc-2026-cloud-front`.
- 생성 후 안내되는 **S3 버킷 정책**(cloudfront.amazonaws.com + SourceArn 조건)을 버킷에 적용.

✅ `curl -I https://<배포도메인>/index` → 200 text/html, `/main` → 200 image/jpeg.

---

## 5. ECR (+ book 이미지 push)
1. **ECR → 프라이빗 리포지토리 생성**: `book-ecr`
   - 태그 불변성 **IMMUTABLE**, **푸시 시 스캔 ON**, 암호화 **KMS = wsc-2026-key**.
2. **CloudShell** 에서 이미지 빌드·푸시(배포파일 book 바이너리 + Dockerfile 준비된 상태):
   ```bash
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   REPO=$ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/book-ecr
   aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
   docker build --platform linux/amd64 -t $REPO:latest .
   docker push $REPO:latest
   ```

✅ `aws ecr describe-repositories --repository-names book-ecr` → IMMUTABLE/KMS/scanOnPush. 스캔 findings CRITICAL/HIGH = 0.

---

## 6. DynamoDB (+ AWS Backup)
### 6-1. 테이블
**DynamoDB → 테이블 생성**: 이름 `wsc-dynamo`, 파티션 키 `booking_id` (문자열).
- 용량 모드 **온디맨드(PAY_PER_REQUEST)**.
- 설정 사용자 지정 → **암호화: AWS 관리형 키**(aws/dynamodb) → SSEType=KMS.
- 생성 후: **PITR 켜기**, **삭제 방지 켜기**.

### 6-2. AWS Backup
1. 백업 저장소는 **`aws/efs/automatic-backup-vault`** 를 사용한다. 이 볼트는 **EFS 자동 백업**을 켜면 자동 생성된다 → EFS 파일시스템 하나 만들고 **자동 백업 ON**(볼트 시드용).
2. **AWS Backup → 백업 계획 생성**:
   - 규칙: 대상 볼트 = `aws/efs/automatic-backup-vault`, 스케줄 매일,
   - **수명 주기: 콜드 스토리지 이동 30일, 만료(삭제) 120일**.
3. **리소스 할당(선택)**: DynamoDB 테이블 `wsc-dynamo` 지정, **IAM 역할 = `AWSBackupDefaultServiceRole`**.

✅ `aws backup get-backup-plan ...` → MoveToColdStorageAfterDays=30, DeleteAfterDays=120, vault=aws/efs/automatic-backup-vault.

---

## 7. EKS 클러스터
**콘솔 또는 eksctl**. eksctl 이 노드그룹까지 한 번에 되므로 CloudShell 권장.
```bash
# CloudShell
cat > cluster.yaml <<'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: wsc-eks-cluster
  region: ap-northeast-2
  version: "1.35"
vpc:
  id: "<wsc-vpc-id>"
  subnets:
    private:
      priv-a: { id: "<priv-sn-a-id>" }
      priv-b: { id: "<priv-sn-b-id>" }
  clusterEndpoints:
    publicAccess: true      # 배포 동안만 (마지막에 false)
    privateAccess: true
secretsEncryption:
  keyARN: "<wsc-2026-key ARN>"
cloudWatch:
  clusterLogging:
    enableTypes: ["api","audit","authenticator","controllerManager","scheduler"]
EOF
eksctl create cluster -f cluster.yaml --without-nodegroup
```
- 프라이빗 서브넷(priv-a/b)에 배치, **secrets KMS 암호화**, **로깅 5종**.

✅ `aws eks describe-cluster --name wsc-eks-cluster` → version 1.35, encryptionConfig(keyArn), logging 5종.

---

## 8. 노드그룹 (app / addon) — eksctl (managed)
```bash
# App 노드그룹: taint 로 book 만 스케줄
eksctl create nodegroup --cluster wsc-eks-cluster --region ap-northeast-2 \
  --name wsc-app-nodegroup --node-type t3.medium --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-private-networking --managed \
  --node-labels "node=app" \
  --node-taints "node=app:NoSchedule"

# Addon 노드그룹
eksctl create nodegroup --cluster wsc-eks-cluster --region ap-northeast-2 \
  --name wsc-addon-nodegroup --node-type t3.medium --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-private-networking --managed \
  --node-labels "node=addon"
```
- 인스턴스 Name 태그: 콘솔 EC2 에서 각 노드에 `wsc-app-node` / `wsc-addon-node` 로 설정(또는 nodegroup 태그).
- Label: app 노드 `node=app`, addon 노드 `node=addon` (Label 없는 노드는 해당 그룹에서 못 쓰게 taint/label).

✅ `aws eks describe-nodegroup ...` → t3.medium, labels node=app/addon.

---

## 9. 앱 배포 (book StatefulSet)
```bash
aws eks update-kubeconfig --region ap-northeast-2 --name wsc-eks-cluster
kubectl create namespace book

# Pod Identity(또는 IRSA) 로 DynamoDB 접근 권한 부여 후 배포
cat > book.yaml <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: book
  namespace: book
  labels: { app: book }
spec:
  serviceName: book
  replicas: 2                      # → book-0, book-1
  selector: { matchLabels: { app: book } }
  template:
    metadata: { labels: { app: book } }
    spec:
      nodeSelector: { node: app }
      tolerations:
        - key: node
          operator: Equal
          value: app
          effect: NoSchedule
      containers:
        - name: book
          image: <ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/book-ecr:latest
          ports: [ { containerPort: 8080 } ]
          env:
            - { name: AWS_REGION, value: ap-northeast-2 }
            - { name: TABLE_NAME, value: wsc-dynamo }
          readinessProbe: { httpGet: { path: /health, port: 8080 } }
          livenessProbe:  { httpGet: { path: /health, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: book, namespace: book }
spec:
  selector: { app: book }
  ports: [ { port: 8080, targetPort: 8080 } ]
EOF
kubectl apply -f book.yaml
```
✅ `kubectl get pods -n book -l app=book` → book-0, book-1 Running. app 노드에만 스케줄됐는지 5-4 명령으로 확인.

---

## 10. ALB (AWS Load Balancer Controller)
1. **LB Controller 설치**(addon 노드에서 구동):
   ```bash
   # IAM 정책/역할(Pod Identity or IRSA) 부여 후
   helm repo add eks https://aws.github.io/eks-charts && helm repo update
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system --set clusterName=wsc-eks-cluster \
     --set region=ap-northeast-2 --set vpcId=<wsc-vpc-id> \
     --set nodeSelector.node=addon
   ```
2. **ALB 생성**(콘솔 EC2 → 로드밸런서, 또는 Ingress/TargetGroupBinding):
   - 이름 `wsc-alb`, **Internet-facing**, 퍼블릭 서브넷(pub-a/b), 리스너 **HTTP 80**.
   - 대상 그룹: **Target type = IP**, 포트 8080, 헬스체크 `/health`.
   - 리스너 규칙: `/health`·`/v1/*` → book 대상그룹 **forward**, **기본 동작 = 고정 응답 404**.
   - book Service 를 대상그룹에 연결(TargetGroupBinding, targetType=ip).

✅ `curl -I http://<wsc-alb DNS>/health` → 200, `POST /v1/book` → `{"booking_id":...}`, 정의 안된 경로 → 404.

---

## 11. Prometheus (kube-prometheus-stack)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
cat > values.yaml <<'EOF'
grafana: { enabled: false }
alertmanager: { enabled: false }
prometheusOperator: { nodeSelector: { node: addon } }
kube-state-metrics: { nodeSelector: { node: addon } }
prometheus:
  prometheusSpec:
    scrapeInterval: 15s
    evaluationInterval: 15s
    nodeSelector: { node: addon }
    ruleSelectorNilUsesHelmValues: false
additionalPrometheusRulesMap:
  book:
    groups:
      - name: book
        rules:
          - alert: BookPodNotRunning
            expr: kube_pod_status_phase{namespace="book",pod=~"book-.*",phase="Running"} == 0
            for: 30s
          - alert: BokPodCrashLooping            # 과제지 표기 그대로(오타 포함)
            expr: increase(kube_pod_container_status_restarts_total{namespace="book",pod=~"book-.*"}[5m]) > 2
            for: 30s
          - alert: BookPodNotReady
            expr: kube_pod_status_ready{namespace="book",condition="true",pod=~"book-.*"} == 0
            for: 30s
EOF
helm install prometheus prometheus-community/kube-prometheus-stack -n prometheus --create-namespace -f values.yaml
```
- 포트 9090 포트포워딩으로 확인:
  ```bash
  kubectl -n prometheus port-forward svc/prometheus-operated 9090:9090
  # 브라우저 http://localhost:9090/alerts
  ```
✅ `kubectl get prometheus -n prometheus -o yaml | grep -E "scrapeInterval|evaluationInterval"` → 둘 다 15s. /alerts 에 3개 룰 표시.

---

## 12. 마무리
1. **EKS private-only 전환**(채점 5-1 PublicEndpoint=False):
   ```bash
   aws eks update-cluster-config --region ap-northeast-2 --name wsc-eks-cluster \
     --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
   ```
2. **채점 계정에 EKS admin 부여**(채점자 접속용):
   ```bash
   PRINCIPAL=$(aws sts get-caller-identity --query Arn --output text)
   aws eks create-access-entry --cluster-name wsc-eks-cluster --principal-arn $PRINCIPAL
   aws eks associate-access-policy --cluster-name wsc-eks-cluster --principal-arn $PRINCIPAL \
     --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
   ```
3. 실행 중이던 부하 테스트/포트포워딩 종료.

---

## 부록 — 콘솔 vs 테라폼
같은 리소스를 테라폼으로 자동화한 버전은 `../../01/1과제/` 에 있다. 값이 30% 바뀌었을 때 어느 파일 어디를 고치는지는 그쪽 `README.md` 의 "값 변경 시 수정 위치" 표 참고.
콘솔로 재현할 때도 이 문서의 각 단계 **이름/CIDR/포트** 만 새 값으로 바꾸면 된다.
