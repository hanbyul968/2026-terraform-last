# =============================================================================
# 01 1과제 — 2단계(k8s/helm) 스테이지
#   root(AWS) apply 가 끝난 뒤 실행한다. 클러스터/ALB/VPC 는 이름으로 data 조회.
#   포함: book Namespace/SA/StatefulSet/Service, AWS LB Controller(helm),
#         kube-prometheus-stack(helm), TargetGroupBinding(kubectl),
#         finalize(EKS private-only 전환).
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_lb_target_group" "book" {
  name = var.tg_name
}

locals {
  image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repo}:latest"
}

# ── book 애플리케이션 (app 노드) ─────────────────────────────────────
resource "kubernetes_namespace_v1" "book" {
  metadata { name = "book" }
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = "book-sa"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
  }
}

resource "kubernetes_stateful_set_v1" "book" {
  metadata {
    name      = "book"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
    labels    = { app = "book" }
  }
  spec {
    service_name = "book"
    replicas     = 2
    selector {
      match_labels = { app = "book" }
    }
    template {
      metadata { labels = { app = "book" } }
      spec {
        service_account_name = kubernetes_service_account_v1.book.metadata[0].name
        node_selector        = { node = "app" }
        toleration {
          key      = "node"
          operator = "Equal"
          value    = "app"
          effect   = "NoSchedule"
        }
        container {
          name              = "book"
          image             = local.image
          image_pull_policy = "Always"
          port { container_port = 8080 }
          env {
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "TABLE_NAME"
            value = var.table_name
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "book" {
  metadata {
    name      = "book"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
  }
  spec {
    selector = { app = "book" }
    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }

  depends_on = [null_resource.wait_lbc_webhook]
}

# ── AWS Load Balancer Controller : IAM(정책+역할) + Pod Identity 연결 ──
#   helm 컨트롤러와 같은 스테이지에 두어 한 apply 에 원자적으로 생성된다.
#   (eks-pod-identity-agent 애드온은 root(1단계)에서 이미 설치됨)
resource "aws_iam_policy" "lb_controller" {
  name   = "wsc-lb-controller-policy"
  policy = file("${path.module}/iam_policy_lb_controller.json")
}

resource "aws_iam_role" "lb_controller" {
  name = "wsc-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}

# ── AWS Load Balancer Controller (helm) ──────────────────────────────
resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  depends_on = [
    aws_eks_pod_identity_association.lb_controller,
    aws_iam_role_policy_attachment.lb_controller,
  ]

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = data.aws_vpc.this.id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "nodeSelector.node"
    value = "addon"
  }
}

# ── LB Controller 웹훅이 실제로 Ready(엔드포인트 보유)될 때까지 대기 ──
#   helm 설치 직후에도 webhook(mservice.elbv2.k8s.aws) 엔드포인트가 잠시 비어 있어,
#   이 사이에 Service(book/kps)를 만들면 "no endpoints available for service
#   aws-load-balancer-webhook-service" 로 실패한다. 아래에서 엔드포인트가 채워질 때까지 기다린다.
resource "null_resource" "wait_lbc_webhook" {
  triggers = { lbc = helm_release.lb_controller.id }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = var.region
      CLUSTER = var.cluster_name
    }
    command = <<-EOT
      set -eu
      export KUBECONFIG=$(mktemp)
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
      kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s || true
      for i in $(seq 1 60); do
        EP=$(kubectl -n kube-system get endpoints aws-load-balancer-webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
        if [ -n "$EP" ]; then echo "LB controller webhook ready: $EP"; exit 0; fi
        sleep 5
      done
      echo "WARN: lb controller webhook endpoints not ready" >&2
      exit 1
    EOT
  }
  depends_on = [helm_release.lb_controller]
}

# ── TargetGroupBinding (book svc -> wsc-book-tg) : kubectl apply ──────
resource "null_resource" "target_group_binding" {
  triggers = {
    tg  = data.aws_lb_target_group.book.arn
    svc = kubernetes_service_v1.book.metadata[0].name
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = var.region
      CLUSTER = var.cluster_name
      TG_ARN  = data.aws_lb_target_group.book.arn
    }
    command = <<-EOT
      set -eu
      export KUBECONFIG=$(mktemp)
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
      f=$(mktemp)
      {
        echo "apiVersion: elbv2.k8s.aws/v1beta1"
        echo "kind: TargetGroupBinding"
        echo "metadata:"
        echo "  name: book-tgb"
        echo "  namespace: book"
        echo "spec:"
        echo "  serviceRef:"
        echo "    name: book"
        echo "    port: 8080"
        echo "  targetType: ip"
        echo "  targetGroupARN: $TG_ARN"
      } > "$f"
      for i in $(seq 1 30); do
        if kubectl apply -f "$f" --validate=false; then exit 0; fi
        sleep 10
      done
      echo "TargetGroupBinding apply failed (CRD not ready?)" >&2
      exit 1
    EOT
  }
  depends_on = [
    helm_release.lb_controller,
    kubernetes_service_v1.book,
  ]
}

# ── kube-prometheus-stack (helm) ─────────────────────────────────────
resource "helm_release" "kps" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "prometheus"
  create_namespace = true

  depends_on = [null_resource.wait_lbc_webhook]

  values = [yamlencode({
    grafana      = { enabled = false }
    alertmanager = { enabled = false }
    prometheusOperator = {
      nodeSelector      = { node = "addon" }
      admissionWebhooks = { patch = { nodeSelector = { node = "addon" } } }
    }
    "kube-state-metrics" = { nodeSelector = { node = "addon" } }
    prometheus = {
      prometheusSpec = {
        scrapeInterval                          = "15s"
        evaluationInterval                      = "15s"
        nodeSelector                            = { node = "addon" }
        ruleSelectorNilUsesHelmValues           = false
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
    additionalPrometheusRulesMap = {
      "book" = {
        groups = [{
          name = "book"
          rules = [
            {
              alert       = "BookPodNotRunning"
              expr        = "kube_pod_status_phase{namespace=\"book\", pod=~\"book-.*\", phase=\"Running\"} == 0"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is not in Running phase" }
            },
            {
              alert       = "BokPodCrashLooping"
              expr        = "increase(kube_pod_container_status_restarts_total{namespace=\"book\", pod=~\"book-.*\"}[5m]) > 2"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is crash looping" }
            },
            {
              alert       = "BookPodNotReady"
              expr        = "kube_pod_status_ready{namespace=\"book\", condition=\"true\", pod=~\"book-.*\"} == 0"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is not Ready" }
            }
          ]
        }]
      }
    }
  })]
}

# ── finalize: 모든 k8s/helm 적용 후 EKS public endpoint 끄기(private-only) ──
resource "null_resource" "private_only" {
  triggers = { cluster = var.cluster_name }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = var.region
      CLUSTER = var.cluster_name
    }
    command = <<-EOT
      set -eu
      CUR=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
      if [ "$CUR" = "True" ] || [ "$CUR" = "true" ]; then
        aws eks update-cluster-config --region "$REGION" --name "$CLUSTER" \
          --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
      fi
      for i in $(seq 1 60); do
        ST=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
        if [ "$ST" = "False" ] || [ "$ST" = "false" ]; then echo "EKS private-only."; exit 0; fi
        sleep 10
      done
      echo "WARN: still public after wait" >&2
      exit 1
    EOT
  }
  depends_on = [
    kubernetes_stateful_set_v1.book,
    kubernetes_service_v1.book,
    null_resource.target_group_binding,
    helm_release.kps,
    helm_release.lb_controller,
  ]
}
