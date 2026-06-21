#!/bin/bash
set -e

CLUSTER="wsi-eks"
REGION="ap-northeast-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
APP_IRSA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/wsi-worker-role"
SQS_QUEUE_URL="https://sqs.ap-northeast-2.amazonaws.com/${ACCOUNT_ID}/wsi-task-queue"
NODE_ROLE_NAME="wsi-system-ng-role"
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/wsi-worker"

echo "=== Updating kubeconfig ==="
aws eks update-kubeconfig --name $CLUSTER --region $REGION

echo "=== Building and pushing worker image ==="
aws ecr create-repository --repository-name wsi-worker --region $REGION 2>/dev/null || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

cat > /tmp/app.py << 'EOF'
import os, time, boto3
from flask import Flask

app = Flask(__name__)
QUEUE_URL = os.environ["QUEUE_URL"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
sqs = boto3.client("sqs", region_name=REGION)

@app.route("/healthz")
def healthz():
    return "ok"

def process(body):
    deadline = time.time() + 60.0
    while time.time() < deadline:
        pass

import threading
def worker():
    while True:
        resp = sqs.receive_message(QueueUrl=QUEUE_URL, MaxNumberOfMessages=1, WaitTimeSeconds=20)
        for m in resp.get("Messages", []):
            process(m.get("Body", ""))
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])

threading.Thread(target=worker, daemon=True).start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

cat > /tmp/Dockerfile << 'EOF'
FROM python:3.11-slim
RUN pip install flask boto3 --quiet
COPY app.py /app.py
CMD ["python", "/app.py"]
EOF

cd /tmp
docker build -t ${ECR_REPO}:latest .
docker push ${ECR_REPO}:latest

echo "=== Applying k8s manifests ==="

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: wsi-app
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wsi-worker-sa
  namespace: wsi-app
  annotations:
    eks.amazonaws.com/role-arn: "${APP_IRSA_ROLE_ARN}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wsi-worker-app
  namespace: wsi-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wsi-worker-app
  template:
    metadata:
      labels:
        app: wsi-worker-app
    spec:
      serviceAccountName: wsi-worker-sa
      tolerations:
        - key: "wsi-nodepool"
          operator: "Exists"
          effect: "NoSchedule"
      nodeSelector:
        karpenter.sh/nodepool: wsi-nodepool
      containers:
        - name: worker
          image: ${ECR_REPO}:latest
          env:
            - name: AWS_REGION
              value: "ap-northeast-2"
            - name: QUEUE_URL
              value: "${SQS_QUEUE_URL}"
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: wsi-keda-scaler
  namespace: wsi-app
spec:
  scaleTargetRef:
    name: wsi-worker-app
  minReplicaCount: 1
  maxReplicaCount: 20
  pollingInterval: 10
  cooldownPeriod: 30
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: "${SQS_QUEUE_URL}"
        queueLength: "5"
        awsRegion: "ap-northeast-2"
        identityOwner: "operator"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: wsi-nodepool
spec:
  template:
    spec:
      taints:
        - key: wsi-nodepool
          effect: NoSchedule
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["c5.large", "c5.xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: wsi-nodeclass
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
  limits:
    cpu: "8"
    memory: "16Gi"
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: wsi-nodeclass
spec:
  amiSelectorTerms:
    - alias: "al2023@latest"
  role: "${NODE_ROLE_NAME}"
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/wsi-eks: shared
  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/wsi-eks: owned
EOF

echo "=== Done! ==="
kubectl get pods -n wsi-app
kubectl get nodepool
kubectl get ec2nodeclass
kubectl -n wsi-app get scaledobject
