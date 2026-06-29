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
}

# ── AWS Load Balancer Controller (helm) ──────────────────────────────
resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

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
      set -euo pipefail
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
        if kubectl apply -f "$f"; then exit 0; fi
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
      set -euo pipefail
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
