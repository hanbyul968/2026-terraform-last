# =============================================================================
# Module 1 / k8s 스테이지  (ap-northeast-2)
#   ../ 에서 EKS 클러스터를 apply 한 뒤 적용한다.
#   - helm: KEDA(ns keda), Karpenter(kube-system)
#   - kubectl: Namespace(wsc-scaling) / Deployment(wsc-scaling-deploy, busybox:latest)
#              / ScaledObject(wsc-scaling-scaledobject, SQS pollingInterval=30, queueLength=5)
#              / Karpenter EC2NodeClass + NodePool
# =============================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

locals {
  cluster_name        = data.terraform_remote_state.infra.outputs.cluster_name
  cluster_endpoint    = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca          = data.terraform_remote_state.infra.outputs.cluster_ca
  cluster_sg_id       = data.terraform_remote_state.infra.outputs.cluster_security_group_id
  keda_role_arn       = data.terraform_remote_state.infra.outputs.keda_role_arn
  karpenter_role_arn  = data.terraform_remote_state.infra.outputs.karpenter_role_arn
  karpenter_node_role = data.terraform_remote_state.infra.outputs.karpenter_node_role_name
  sqs_queue_url       = data.terraform_remote_state.infra.outputs.sqs_queue_url
}

data "aws_eks_cluster_auth" "main" {
  name = local.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  token                  = data.aws_eks_cluster_auth.main.token
  load_config_file       = false
}

# ── KEDA ──────────────────────────────────────────────────────────────────────
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  timeout          = 600

  set {
    name  = "serviceAccount.operator.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.keda_role_arn
  }
}

# ── Karpenter ─────────────────────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "kube-system"
  timeout    = 600

  set {
    name  = "settings.clusterName"
    value = local.cluster_name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = local.cluster_endpoint
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.karpenter_role_arn
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────
resource "kubectl_manifest" "namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: wsc-scaling
  YAML
}

# ── Deployment (busybox:latest) ───────────────────────────────────────────────
resource "kubectl_manifest" "deployment" {
  yaml_body  = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: wsc-scaling-deploy
      namespace: wsc-scaling
      labels:
        dedicated: scaling
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: wsc-scaling-deploy
      template:
        metadata:
          labels:
            app: wsc-scaling-deploy
            dedicated: scaling
        spec:
          containers:
          - name: app
            image: busybox:latest
            command: ["sh", "-c", "while true; do sleep 30; done"]
            resources:
              requests:
                cpu: "250m"
                memory: "256Mi"
              limits:
                cpu: "500m"
                memory: "512Mi"
  YAML
  depends_on = [kubectl_manifest.namespace]
}

# ── KEDA ScaledObject (SQS) ───────────────────────────────────────────────────
#   minReplicaCount=2(메시지 없을 때 유지), pollingInterval=30, queueLength=5(5msg/pod)
resource "kubectl_manifest" "scaledobject" {
  yaml_body  = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: wsc-scaling-scaledobject
      namespace: wsc-scaling
    spec:
      scaleTargetRef:
        name: wsc-scaling-deploy
      minReplicaCount: 2
      maxReplicaCount: 50
      pollingInterval: 30
      cooldownPeriod: 30
      triggers:
      - type: aws-sqs-queue
        metadata:
          queueURL: "${local.sqs_queue_url}"
          queueLength: "5"
          awsRegion: "ap-northeast-2"
          identityOwner: operator
  YAML
  depends_on = [kubectl_manifest.deployment, helm_release.keda]
}

# ── Karpenter EC2NodeClass / NodePool ─────────────────────────────────────────
resource "kubectl_manifest" "nodeclass" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: wsc-scaling-nodeclass
    spec:
      role: "${local.karpenter_node_role}"
      amiSelectorTerms:
      - alias: al2023@latest
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: "wsc-scaling-cluster"
      securityGroupSelectorTerms:
      - id: "${local.cluster_sg_id}"
  YAML
  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: wsc-scaling-nodepool
    spec:
      template:
        metadata:
          labels:
            dedicated: scaling
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: wsc-scaling-nodeclass
          requirements:
          - key: karpenter.k8s.aws/instance-family
            operator: In
            values: ["t3", "c5", "m5"]
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand"]
      limits:
        cpu: "100"
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s
  YAML
  depends_on = [kubectl_manifest.nodeclass]
}
