# 모듈 4 — Container Logging / O11y (콘솔 + CloudShell 솔루션)

**리전: `ap-northeast-1` (도쿄)**

EKS + OpenTelemetry Collector(DaemonSet) + Loki + Grafana 통합 로깅 시스템.

> EKS/IAM/ALB/TG 는 **콘솔**, 워크로드·Loki·Grafana·OTel(helm/kubectl)은
> **CloudShell(ap-northeast-1)** 로 진행합니다.

## 만들 리소스 요약
| 리소스 | 이름 | 설정 |
|--------|------|------|
| EKS | `o11y-cluster` | v1.35, 노드 TimeZone=KST 권장 |
| NodeGroup | `o11y-cluster-ng` | t3.medium, 2/2/2, Multi-AZ (1a/1c) |
| ALB/TG | `o11y-app-alb`/`o11y-app-tg`(8080), `o11y-grafana-alb`/`o11y-grafana-tg`(3000) |
| App | `log-generator` (o11y ns, 2 replicas) |
| OTel | `o11y-otel` DaemonSet (monitoring ns) |
| Loki | `o11y-loki` (SingleBinary, OTLP) |
| Grafana | `o11y-grafana` (Log Overview 대시보드) |

---

## 1. VPC (2개 퍼블릭 서브넷, 1a/1c)

콘솔 → **VPC** → **VPC 등 여러 리소스**
1. 이름 `o11y`, CIDR `10.0.0.0/16`
2. 가용영역 2개: **ap-northeast-1a**, **ap-northeast-1c**, 퍼블릭 서브넷 2개
3. 두 서브넷 태그:
   - `kubernetes.io/cluster/o11y-cluster` = `shared`
   - `kubernetes.io/role/elb` = `1`

> ✅ 채점 4-1: 노드 zone 이 **1a, 1c 로 서로 달라야** 득점(Multi-AZ).

---

## 2. IAM 역할

- **클러스터 역할** `o11y-cluster-role`: 신뢰 EKS, 정책 `AmazonEKSClusterPolicy`
- **노드 역할** `o11y-cluster-ng-role`: 신뢰 EC2, 정책 3종
  (`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`)

---

## 3. EKS 클러스터 + 노드그룹 (콘솔)

### 3-1. 클러스터
EKS → 클러스터 생성 → 이름 `o11y-cluster`, 버전 **1.35**, 역할 `o11y-cluster-role`,
VPC/서브넷 2개, 인증모드 **EKS API 및 ConfigMap**. → 생성.
- **본인 계정 Access Entry**: 액세스 탭 → `AmazonEKSClusterAdminPolicy` 부여 (kubectl 채점용)

### 3-2. 노드 TimeZone KST (선택, 시작 템플릿)
EC2 → 시작 템플릿 `o11y-ng-lt` 생성 → **고급 → 사용자 데이터**:
```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="

--==MYBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
echo "Asia/Seoul" > /etc/timezone

--==MYBOUNDARY==--
```

### 3-3. 노드그룹
EKS → 컴퓨팅 → 노드 그룹 추가 → 이름 `o11y-cluster-ng`, 역할 `o11y-cluster-ng-role`,
(시작 템플릿 `o11y-ng-lt` 선택 시 KST 적용), 인스턴스 t3.medium, 크기 **2/2/2**, 서브넷 2개.

### 3-4. EBS CSI 드라이버
- IAM 역할 `o11y-ebs-csi-role`: 웹 자격 증명(OIDC), SA `kube-system:ebs-csi-controller-sa`,
  정책 `AmazonEBSCSIDriverPolicy`
- EKS → 추가 기능 → **Amazon EBS CSI Driver** 설치, 서비스 역할 위 역할 지정.

> ✅ 채점 4-1: o11y-cluster 1.35 ACTIVE, t3.medium 2 2 2, zone 1a≠1c

---

## 4. OIDC + ALB Controller IRSA

- **OIDC 공급자** 등록 (모듈3 6-2 동일 방식)
- **역할** `o11y-alb-controller-role`: 웹 자격 증명, SA
  `kube-system:aws-load-balancer-controller`, 정책 `ElasticLoadBalancingFullAccess`
  + 인라인(EC2 Describe/CreateSecurityGroup/CreateTags, elasticloadbalancing:*, wafv2:*,
  shield:*, acm:*, tag:* 등 ALB Controller 필요 권한).

---

## 5. ALB / Target Group (콘솔)

### 5-1. ALB 보안 그룹 `o11y-alb-sg`
VPC `o11y`, 인바운드 TCP 80 `0.0.0.0/0`, 아웃바운드 all.
- 추가로 **클러스터 보안그룹**(EKS가 만든 것)에 인바운드 8080·3000 을 `o11y-alb-sg` 소스로 허용.

### 5-2. App ALB + TG
EC2 → 로드밸런서 → **Application Load Balancer**
1. 이름 `o11y-app-alb`, 인터넷 경계, 서브넷 2개, SG `o11y-alb-sg`
2. **대상 그룹 생성**: 이름 `o11y-app-tg`, **IP** 유형, 포트 **8080**, VPC `o11y`,
   헬스체크 경로 `/healthz`
3. 리스너 HTTP:80 → `o11y-app-tg` 전달.

### 5-3. Grafana ALB + TG
1. ALB 이름 `o11y-grafana-alb` (동일 방식)
2. TG 이름 `o11y-grafana-tg`, IP 유형, 포트 **3000**, 헬스체크 `/api/health`
3. 리스너 HTTP:80 → `o11y-grafana-tg`.

> ✅ 채점 4-2: 두 ALB active/application/internet-facing, TG targets healthy

---

## 6. CloudShell — 앱/OTel/Loki/Grafana 배포

**CloudShell(ap-northeast-1)** 을 엽니다. 이미지 빌드는 docker 필요(로컬/Bastion에서).

### 6-1. log-generator 이미지 빌드/푸시 (docker 있는 환경)
`app.py`:
```python
import json, sys, uuid
from datetime import datetime, timezone
from flask import Flask, jsonify, request
app = Flask(__name__)

def _ts():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

@app.get("/healthz")
def healthz(): return jsonify({"status": "ok"}), 200

@app.get("/log")
def gen():
    level = request.args.get("level", "info").upper()
    if level not in {"INFO","WARN","ERROR"}:
        return jsonify({"error": "level must be one of info, warn, error"}), 400
    try: count = int(request.args.get("count", "1"))
    except ValueError: return jsonify({"error": "count must be an integer"}), 400
    count = max(1, min(count, 1000))
    for _ in range(count):
        print(json.dumps({"ts": _ts(), "level": level, "msg": "log generated",
                          "req_id": str(uuid.uuid4())}, separators=(",", ":")), flush=True)
        sys.stdout.flush()
    return jsonify({"generated": count, "level": level.lower()}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```
`Dockerfile` (flask 설치 필수):
```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```
빌드/푸시:
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text); REGION=ap-northeast-1
aws ecr create-repository --repository-name o11y-log-generator --region $REGION 2>/dev/null || true
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/o11y-log-generator
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
docker build --platform linux/amd64 -t $REPO:latest .
docker push $REPO:latest
```

### 6-2. kubeconfig + Helm (ALB Controller, Loki, Grafana)
```bash
number=<선수등번호>          # ← 교체
REGION=ap-northeast-1; CLUSTER=o11y-cluster
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

helm repo add eks https://aws.github.io/eks-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
ALB_ROLE=$(aws iam get-role --role-name o11y-alb-controller-role --query "Role.Arn" --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=$CLUSTER --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_ROLE \
  --set vpcId=$VPC_ID --wait --timeout 5m

# Loki (SingleBinary + OTLP 인제스션)
helm upgrade --install o11y-loki grafana/loki -n monitoring --create-namespace \
  --set deploymentMode=SingleBinary --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=true --set singleBinary.persistence.size=10Gi \
  --set loki.auth_enabled=false --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem --set loki.limits_config.allow_structured_metadata=true \
  --set 'loki.schemaConfig.configs[0].from=2024-01-01' \
  --set 'loki.schemaConfig.configs[0].store=tsdb' \
  --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
  --set 'loki.schemaConfig.configs[0].schema=v13' \
  --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
  --set 'loki.schemaConfig.configs[0].index.period=24h' \
  --set chunksCache.enabled=false --set resultsCache.enabled=false \
  --set backend.replicas=0 --set read.replicas=0 --set write.replicas=0 --timeout 10m

# Grafana (Loki Datasource 등록)
helm upgrade --install o11y-grafana grafana/grafana -n monitoring --create-namespace \
  --set adminUser="skills${number}" --set adminPassword="GoodJob!Skills${number}^^" \
  --set service.type=ClusterIP \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Loki' \
  --set 'datasources.datasources\.yaml.datasources[0].type=loki' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://o11y-loki:3100' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy' \
  --set 'datasources.datasources\.yaml.datasources[0].isDefault=true' \
  --wait --timeout 5m
```

### 6-3. log-generator + TargetGroupBinding + OTel Collector
```bash
REGION=ap-northeast-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/o11y-log-generator
kubectl create namespace o11y --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: log-generator, namespace: o11y }
spec:
  replicas: 2
  selector: { matchLabels: { app: log-generator } }
  template:
    metadata: { labels: { app: log-generator } }
    spec:
      containers:
        - name: log-generator
          image: ${REPO}:latest
          ports: [{ containerPort: 8080 }]
          livenessProbe:  { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
          readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
---
apiVersion: v1
kind: Service
metadata: { name: log-generator, namespace: o11y }
spec:
  selector: { app: log-generator }
  ports: [{ port: 8080, targetPort: 8080 }]
  type: ClusterIP
EOF

APP_TG=$(aws elbv2 describe-target-groups --names o11y-app-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)
GRAFANA_TG=$(aws elbv2 describe-target-groups --names o11y-grafana-tg --region $REGION --query "TargetGroups[0].TargetGroupArn" --output text)
cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: o11y-app-tgb, namespace: o11y }
spec: { serviceRef: { name: log-generator, port: 8080 }, targetGroupARN: ${APP_TG}, targetType: ip }
---
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: o11y-grafana-tgb, namespace: monitoring }
spec: { serviceRef: { name: o11y-grafana, port: 80 }, targetGroupARN: ${GRAFANA_TG}, targetType: ip }
EOF
```

**OTel Collector (filelog + k8sattributes + OTLP → Loki):**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: { name: o11y-otel-sa, namespace: monitoring }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: o11y-otel-role }
rules: [{ apiGroups: [""], resources: ["pods","namespaces","nodes"], verbs: ["get","list","watch"] }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: o11y-otel-rolebinding }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: o11y-otel-role }
subjects: [{ kind: ServiceAccount, name: o11y-otel-sa, namespace: monitoring }]
---
apiVersion: v1
kind: ConfigMap
metadata: { name: o11y-otel-config, namespace: monitoring }
data:
  config.yaml: |
    receivers:
      filelog:
        include: [/var/log/pods/*/*/*.log]
        include_file_path: true
        start_at: beginning
        operators:
          - type: container
            id: container-parser
    processors:
      k8sattributes:
        auth_type: serviceAccount
        extract:
          metadata: [k8s.namespace.name, k8s.pod.name, k8s.container.name, k8s.node.name]
        pod_association:
          - sources: [{ from: resource_attribute, name: k8s.pod.uid }]
          - sources: [{ from: connection }]
    exporters:
      otlphttp:
        endpoint: http://o11y-loki.monitoring.svc.cluster.local:3100/otlp
        tls: { insecure: true }
    service:
      pipelines:
        logs: { receivers: [filelog], processors: [k8sattributes], exporters: [otlphttp] }
---
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: o11y-otel, namespace: monitoring }
spec:
  selector: { matchLabels: { app: o11y-otel } }
  template:
    metadata: { labels: { app: o11y-otel } }
    spec:
      serviceAccountName: o11y-otel-sa
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:latest
          args: ["--config=/etc/otel/config.yaml"]
          volumeMounts:
            - { name: config, mountPath: /etc/otel }
            - { name: varlogpods, mountPath: /var/log/pods, readOnly: true }
            - { name: varlibdockercontainers, mountPath: /var/lib/docker/containers, readOnly: true }
      volumes:
        - { name: config, configMap: { name: o11y-otel-config } }
        - { name: varlogpods, hostPath: { path: /var/log/pods } }
        - { name: varlibdockercontainers, hostPath: { path: /var/lib/docker/containers } }
EOF
```

> ✅ 채점 4-3: log-generator 2, o11y-otel DESIRED=READY 2, o11y-loki ClusterIP 3100, o11y-grafana 1

---

## 7. Grafana 'Log Overview' 대시보드 (4-6)

CloudShell 에서 Grafana API 로 대시보드 생성:
```bash
number=<선수등번호>; REGION=ap-northeast-1
GRAFANA=$(aws elbv2 describe-load-balancers --names o11y-grafana-alb --region $REGION --query 'LoadBalancers[0].DNSName' --output text)
# Grafana 헬스 대기
for i in $(seq 1 12); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://$GRAFANA/api/health)" = "200" ] && break; sleep 10; done
LOKI_UID=$(curl -s -u "skills${number}:GoodJob!Skills${number}^^" "http://$GRAFANA/api/datasources" | jq -r '.[0].uid')

cat > /tmp/dash.json <<EOF
{"dashboard":{"title":"Log Overview","uid":"log-overview","panels":[
{"id":1,"title":"Log Count Over Time","type":"timeseries","gridPos":{"h":9,"w":14,"x":0,"y":0},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"fieldConfig":{"defaults":{"custom":{"drawStyle":"bars","fillOpacity":80,"stacking":{"mode":"normal","group":"A"}}}},"options":{"legend":{"displayMode":"list","placement":"bottom"}},"targets":[{"expr":"sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | level=~\"INFO|WARN|ERROR\" [1m]))","refId":"A","legendFormat":"{{level}}"}]},
{"id":2,"title":"Log Level Distribution","type":"piechart","gridPos":{"h":9,"w":10,"x":14,"y":0},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"options":{"legend":{"displayMode":"list","placement":"right"}},"targets":[{"expr":"sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | level=~\"INFO|WARN|ERROR\" [\$__range]))","refId":"A","legendFormat":"{{level}}"}]},
{"id":3,"title":"Recent Logs","type":"logs","gridPos":{"h":12,"w":24,"x":0,"y":9},"datasource":{"type":"loki","uid":"${LOKI_UID}"},"targets":[{"expr":"{k8s_namespace_name=\"o11y\"} | json","refId":"A"}]}
],"schemaVersion":39,"time":{"from":"now-1h","to":"now"},"refresh":"10s"},"overwrite":true}
EOF
curl -s -X POST -H "Content-Type: application/json" -u "skills${number}:GoodJob!Skills${number}^^" \
  "http://$GRAFANA/api/dashboards/db" --data-binary @/tmp/dash.json
```

> ✅ 4-6: 패널 3개(막대/원/로그), 범례 `{{level}}` → INFO/WARN/ERROR **plain text**,
> No Data 없이 표시, Loki Datasource **Save & Test** 성공.

---

## 8. 검증 (채점 기준)

### 8-1. App API (4-4)
```bash
ALB=$(aws elbv2 describe-load-balancers --names o11y-app-alb --region ap-northeast-1 --query 'LoadBalancers[0].DNSName' --output text)
curl -s "http://$ALB/healthz"; echo
curl -s "http://$ALB/log?level=error&count=3" | head -1 | jq -r '.level, .generated'
```
기대: `{"status":"ok"}` / `error` / `3`

### 8-2. 로그 파이프라인 (4-5) — 명령을 한 줄씩 따로 실행!
```bash
# 1) 에러 로그 생성
ALB=$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)
curl -s "http://$ALB/log?level=error&count=3"; echo
```
```bash
# 2) Loki 포트포워딩 (이 줄만 단독 실행 — 백그라운드 유지)
kubectl port-forward -n monitoring svc/o11y-loki 3100:3100 >/dev/null 2>&1 &
```
```bash
# 3) 조회 (백슬래시 없이 한 줄)
curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode 'query={k8s_namespace_name="o11y"}' --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'
```
→ `{"ts":...,"level":"ERROR",...}` 라인이 나오면 4-5 득점.
```bash
# 4) 종료
kill %1 2>/dev/null
```

> ⚠️ 여러 줄을 붙여넣어 한 줄로 합치면 port-forward 가 바로 종료되어 조회가 빈 결과가 됩니다.

### 8-3. Grafana 대시보드 (4-6, 수동)
- `http://<o11y-grafana-alb DNS>` 접속 → `skills<번호>` / `GoodJob!Skills<번호>^^`
- **Log Overview** 대시보드: 3개 패널 No Data 없이 표시, 범례 plain text
- Recent Logs 에 8-2 로그 표시
- Connections → Data sources → Loki → **Save & Test** 성공
