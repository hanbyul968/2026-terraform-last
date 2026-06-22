terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
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

# ── 클러스터 폴더(../)의 상태를 읽어옴 ────────────────────────────────
# 먼저 ../ 에서 terraform apply 로 클러스터를 만든 뒤 이 폴더를 apply 한다.
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../terraform.tfstate"
  }
}

locals {
  cluster_name        = data.terraform_remote_state.cluster.outputs.cluster_name
  cluster_endpoint    = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca          = data.terraform_remote_state.cluster.outputs.cluster_ca
  cluster_sg_id       = data.terraform_remote_state.cluster.outputs.cluster_security_group_id
  keda_irsa_arn       = data.terraform_remote_state.cluster.outputs.keda_irsa_role_arn
  karpenter_irsa_arn  = data.terraform_remote_state.cluster.outputs.karpenter_irsa_role_arn
  app_irsa_arn        = data.terraform_remote_state.cluster.outputs.app_irsa_role_arn
  karpenter_node_role = data.terraform_remote_state.cluster.outputs.karpenter_node_role_name
  sqs_queue_url       = data.terraform_remote_state.cluster.outputs.sqs_queue_url
}

# 클러스터가 이미 존재하므로 endpoint/token 이 확정값 → provider 정상 동작
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

# ── KEDA ──────────────────────────────────────────────────────────────
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.keda_irsa_arn
  }
  set {
    name  = "tolerations[0].key"
    value = "dedicated"
  }
  set {
    name  = "tolerations[0].value"
    value = "addon"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

# ── Karpenter ─────────────────────────────────────────────────────────
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
    value = local.karpenter_irsa_arn
  }
  set {
    name  = "tolerations[0].key"
    value = "dedicated"
  }
  set {
    name  = "tolerations[0].value"
    value = "addon"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

# ── Kubernetes Manifests ──────────────────────────────────────────────
resource "kubectl_manifest" "namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: wsi-app
  YAML
}

resource "kubectl_manifest" "service_account" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: wsi-worker-sa
      namespace: wsi-app
      annotations:
        eks.amazonaws.com/role-arn: "${local.app_irsa_arn}"
  YAML
  depends_on = [kubectl_manifest.namespace]
}

# 배포파일 app.py 를 ConfigMap 으로 → 컨테이너 /app 에 마운트
resource "kubectl_manifest" "app_code" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "wsi-worker-code"
      namespace = "wsi-app"
    }
    data = {
      "app.py" = file("${path.module}/../app.py")
    }
  })
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: wsi-worker-app
      namespace: wsi-app
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: wsi-worker-app
      template:
        metadata:
          labels:
            app: wsi-worker-app
        spec:
          serviceAccountName: wsi-worker-sa
          containers:
          - name: worker
            image: python:3.11-slim
            command: ["sh", "-c", "pip install --no-cache-dir --quiet boto3 && python /app/app.py"]
            env:
            - name: QUEUE_URL
              value: "${local.sqs_queue_url}"
            - name: AWS_REGION
              value: "ap-northeast-2"
            resources:
              requests:
                cpu: "200m"
                memory: "128Mi"
              limits:
                cpu: "500m"
                memory: "256Mi"
            volumeMounts:
            - name: app-code
              mountPath: /app
          volumes:
          - name: app-code
            configMap:
              name: wsi-worker-code
  YAML
  depends_on = [kubectl_manifest.service_account, kubectl_manifest.app_code, helm_release.keda]
}

resource "kubectl_manifest" "scaledobject" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: wsi-keda-scaler
      namespace: wsi-app
    spec:
      scaleTargetRef:
        name: wsi-worker-app
      minReplicaCount: 0
      maxReplicaCount: 20
      triggers:
      - type: aws-sqs-queue
        metadata:
          queueURL: "${local.sqs_queue_url}"
          queueLength: "1"
          awsRegion: "ap-northeast-2"
          identityOwner: operator
  YAML
  depends_on = [kubectl_manifest.deployment]
}

resource "kubectl_manifest" "nodeclass" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: wsi-nodeclass
    spec:
      role: "${local.karpenter_node_role}"
      amiSelectorTerms:
      - alias: al2023@latest
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: "wsi-eks"
      securityGroupSelectorTerms:
      - id: "${local.cluster_sg_id}"
  YAML
  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: wsi-nodepool
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: wsi-nodeclass
          requirements:
          - key: karpenter.k8s.aws/instance-family
            operator: In
            values: ["c5"]
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
      limits:
        cpu: "100"
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s
  YAML
  depends_on = [kubectl_manifest.nodeclass]
}
