#!/bin/bash
set -e

REGION=us-west-2
CLUSTER=skills-sqs-cluster
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws eks update-kubeconfig --region $REGION --name $CLUSTER

# Namespaces
kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace skills-sqs --dry-run=client -o yaml | kubectl apply -f -

# Get role ARNs from terraform output
KEDA_ROLE=$(terraform -chdir=module4 output -raw keda_role_arn)
KARPENTER_ROLE=$(terraform -chdir=module4 output -raw karpenter_role_arn)
WORKER_ROLE=$(terraform -chdir=module4 output -raw worker_role_arn)
NODE_ROLE=$(terraform -chdir=module4 output -raw node_role_arn)
SQS_URL=$(terraform -chdir=module4 output -raw sqs_queue_url)
NODE_PROFILE=$(terraform -chdir=module4 output -raw node_instance_profile)

# Install KEDA via Helm
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda --namespace keda \
  --set serviceAccount.operator.annotations."eks\.amazonaws\.com/role-arn"="$KEDA_ROLE"

# Install Karpenter via Helm
helm repo add karpenter https://charts.karpenter.sh
helm repo update
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.4.0 --namespace karpenter \
  --set "settings.clusterName=$CLUSTER" \
  --set "settings.clusterEndpoint=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.endpoint --output text)" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE"

# Worker SA
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sqs-worker-sa
  namespace: skills-sqs
  annotations:
    eks.amazonaws.com/role-arn: "$WORKER_ROLE"
EOF

# Worker Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqs-worker
  namespace: skills-sqs
spec:
  replicas: 0
  selector:
    matchLabels:
      app: sqs-worker
  template:
    metadata:
      labels:
        app: sqs-worker
    spec:
      serviceAccountName: sqs-worker-sa
      nodeSelector:
        karpenter.sh/nodepool: skills-sqs-nodepool
        skills-nodepool: event-worker
      containers:
      - name: worker
        image: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/skills-sqs-worker:latest
        env:
        - name: SQS_QUEUE_URL
          value: "$SQS_URL"
        - name: AWS_REGION
          value: "$REGION"
        - name: PROCESSING_SECONDS
          value: "5"
EOF

# KEDA TriggerAuthentication
cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: sqs-worker-trigger-auth
  namespace: skills-sqs
spec:
  podIdentity:
    provider: aws
EOF

# KEDA ScaledObject
cat <<EOF | kubectl apply -f -
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-worker-scaledobject
  namespace: skills-sqs
spec:
  scaleTargetRef:
    name: sqs-worker
  pollingInterval: 15
  cooldownPeriod: 30
  minReplicaCount: 0
  maxReplicaCount: 6
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: sqs-worker-trigger-auth
    metadata:
      queueURL: "$SQS_URL"
      queueLength: "2"
      awsRegion: "$REGION"
EOF

# Karpenter NodePool
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: skills-sqs-nodepool
spec:
  template:
    metadata:
      labels:
        skills-nodepool: event-worker
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: skills-sqs-nodeclass
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["t3.medium", "t3.large"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: 100
EOF

# Karpenter EC2NodeClass
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: skills-sqs-nodeclass
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  role: "${NODE_ROLE##*/}"
  subnetSelectorTerms:
  - tags:
      kubernetes.io/cluster/$CLUSTER: owned
  securityGroupSelectorTerms:
  - tags:
      kubernetes.io/cluster/$CLUSTER: owned
EOF

# Tag subnets for Karpenter discovery
for subnet in $(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text)" --query "Subnets[].SubnetId" --output text); do
  aws ec2 create-tags --region $REGION --resources $subnet --tags Key=kubernetes.io/cluster/$CLUSTER,Value=owned
done

# Build and push worker image
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
aws ecr create-repository --repository-name skills-sqs-worker --region $REGION 2>/dev/null || true
cd app/module4
docker build -t skills-sqs-worker .
docker tag skills-sqs-worker:latest ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/skills-sqs-worker:latest
docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/skills-sqs-worker:latest

echo "Module 4 K8s resources deployed!"
