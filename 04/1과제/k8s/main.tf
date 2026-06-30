# =============================================================================
# 04 1과제 — 2단계(k8s/helm) 스테이지
#   root(AWS) apply 가 끝난 뒤 실행한다. 클러스터/VPC/Subnet/ALB-TG/KMS 는 data 로 조회.
#   포함:
#     - App        : wsc/logging/monitoring Namespace, book-sa, wsc-config ConfigMap,
#                    wsc-deploy Deployment/Service, wsc-sc StorageClass
#     - LB         : AWS LB Controller(helm), book TargetGroupBinding(kubectl)
#     - Logging    : fluent-bit SA + aws-for-fluent-bit(helm)
#     - Monitoring : prometheus/grafana PVC, wsc-eks-dashboard, prometheus/grafana(helm),
#                    wsc-addon-ingress
#     - finalize   : 모든 적용 후 EKS public->private 전환(null_resource)
# =============================================================================

# ── root(AWS) 산출물 data 조회 ────────────────────────────────────────
data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnet" "public_a" {
  filter {
    name   = "tag:Name"
    values = [var.public_subnet_a_name]
  }
}

data "aws_subnet" "public_c" {
  filter {
    name   = "tag:Name"
    values = [var.public_subnet_c_name]
  }
}

data "aws_lb_target_group" "book" {
  name = var.tg_name
}

data "aws_kms_key" "main" {
  key_id = var.kms_alias
}

locals {
  region    = var.region
  registry  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repo}:${var.image_tag}"
}

# ═══════════════════════════════════════════════════════════════
# Kubernetes - App (과제 9.3 ~ 9.6)
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "wsc" {
  metadata { name = "wsc" }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata { name = "logging" }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata { name = "monitoring" }
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = "book-sa"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
  }
}

# ── ConfigMap (환경변수, 과제 9.5) ──
resource "kubernetes_config_map_v1" "wsc" {
  metadata {
    name      = "wsc-config"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
  }
  data = {
    AWS_REGION = local.region
    TABLE_NAME = var.table_name
  }
}

# ── Deployment (과제 9.3) ──
resource "kubernetes_deployment_v1" "wsc" {
  metadata {
    name      = "wsc-deploy"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
    labels    = { app = "wsc-deploy" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "wsc-deploy" }
    }
    template {
      metadata {
        labels = { app = "wsc-deploy" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.book.metadata[0].name
        # App 은 반드시 app 노드그룹에서만 (과제 9.3)
        node_selector = { type = "app" }
        container {
          name  = "wsc-cnt"
          image = local.image_url
          port {
            container_port = 8080
          }
          # 환경변수는 ConfigMap 참조 (하드코딩 금지, 채점 6-7-B)
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.wsc.metadata[0].name
            }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

# book Service (LB Controller TargetGroupBinding 대상). port 80 -> 8080
resource "kubernetes_service_v1" "wsc" {
  metadata {
    name      = "wsc-deploy"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
  }
  spec {
    selector = { app = "wsc-deploy" }
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# ── StorageClass wsc-sc (EBS CSI, CMK, 동적 프로비저닝) ──
resource "kubernetes_storage_class_v1" "wsc" {
  metadata {
    name = "wsc-sc"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = data.aws_kms_key.main.arn
  }
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller (addon LB / wsc-addon-lb 및 book TGB 관리)
#   IAM/Pod Identity 는 root 에 있고, 여기서는 helm 차트만 설치한다.
# ═══════════════════════════════════════════════════════════════
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
    value = local.region
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
  # addon 노드그룹에 스케줄
  set {
    name  = "nodeSelector.type"
    value = "addon"
  }
}

# book Service -> book TG 바인딩 (TargetGroupBinding CRD)
resource "null_resource" "book_tgb" {
  triggers = {
    tg  = data.aws_lb_target_group.book.arn
    svc = "wsc-deploy"
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = local.region
      CLUSTER = var.cluster_name
      TG_ARN  = data.aws_lb_target_group.book.arn
    }
    command = <<-EOT
      set -eu
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
      f=$(mktemp)
      {
        echo "apiVersion: elbv2.k8s.aws/v1beta1"
        echo "kind: TargetGroupBinding"
        echo "metadata:"
        echo "  name: wsc-book-tgb"
        echo "  namespace: wsc"
        echo "spec:"
        echo "  serviceRef:"
        echo "    name: wsc-deploy"
        echo "    port: 80"
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
    kubernetes_service_v1.wsc,
  ]
}

# ═══════════════════════════════════════════════════════════════
# Logging  (과제 10) — Fluent Bit DaemonSet
#   IAM/Pod Identity/Log Group 은 root 에 있고, 여기서는 SA + helm 만.
# ═══════════════════════════════════════════════════════════════
resource "kubernetes_service_account_v1" "fluentbit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [templatefile("${path.module}/fluentbit-values.yaml.tftpl", {
    log_group  = var.log_group_name
    log_stream = var.log_stream_name
    region     = local.region
    registry   = local.registry
    sa_name    = kubernetes_service_account_v1.fluentbit.metadata[0].name
  })]

  depends_on = [
    helm_release.lb_controller,
  ]
}

# ═══════════════════════════════════════════════════════════════
# Observability & Monitoring  (과제 11) + Addon LB (과제 12.2)
# ═══════════════════════════════════════════════════════════════

# ── 고정 이름 PVC (채점이 이름을 정확히 확인) ──
resource "kubernetes_persistent_volume_claim_v1" "prometheus" {
  metadata {
    name      = "wsc-prometheus-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.wsc.metadata[0].name
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "grafana" {
  metadata {
    name      = "wsc-grafana-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.wsc.metadata[0].name
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

# ── Grafana dashboard (wsc-eks-dashboard) ──
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = "wsc-eks-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wsc-eks-dashboard.json" = file("${path.module}/wsc-eks-dashboard.json")
  }
}

# ── Prometheus ──
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/prometheus-values.yaml.tftpl", {
    registry = local.registry
    pvc_name = kubernetes_persistent_volume_claim_v1.prometheus.metadata[0].name
  })]

  depends_on = [
    kubernetes_storage_class_v1.wsc,
    helm_release.lb_controller,
  ]
}

# ── Grafana ──
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/grafana-values.yaml.tftpl", {
    registry       = local.registry
    pvc_name       = kubernetes_persistent_volume_claim_v1.grafana.metadata[0].name
    admin_password = var.grafana_admin_password
    ds_url         = "http://prometheus-server.monitoring.svc.${var.cluster_dns_domain}/prometheus"
  })]

  depends_on = [
    helm_release.prometheus,
    kubernetes_config_map_v1.dashboard,
  ]
}

# ── Addon LB (public, ingress 로 생성) : /grafana, /prometheus ──
resource "kubernetes_ingress_v1" "addon" {
  metadata {
    name      = "wsc-addon-ingress"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name" = "wsc-addon-lb"
      "alb.ingress.kubernetes.io/subnets"            = "${data.aws_subnet.public_a.id},${data.aws_subnet.public_c.id}"
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\":80}]"
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/grafana"
          path_type = "Prefix"
          backend {
            service {
              name = "grafana"
              port { number = 80 }
            }
          }
        }
        path {
          path      = "/prometheus"
          path_type = "Prefix"
          backend {
            service {
              name = "prometheus-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.grafana, helm_release.prometheus, helm_release.lb_controller]
}

# ═══════════════════════════════════════════════════════════════
# finalize: 모든 k8s/helm 적용 후 EKS public endpoint 끄기(private-only)
#   - 채점 6-1: endpointPublicAccess=False, endpointPrivateAccess=True
# ═══════════════════════════════════════════════════════════════
resource "null_resource" "private_only" {
  triggers = {
    cluster = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = local.region
      CLUSTER = var.cluster_name
    }
    command = <<-EOT
      set -eu
      # 현재 public 이면 끈다 (idempotent)
      CUR=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
        --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
      if [ "$CUR" = "True" ] || [ "$CUR" = "true" ]; then
        aws eks update-cluster-config --region "$REGION" --name "$CLUSTER" \
          --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
      fi
      # 실제 False 로 반영될 때까지 대기 (최대 ~10분)
      for i in $(seq 1 60); do
        ST=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
          --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
        if [ "$ST" = "False" ] || [ "$ST" = "false" ]; then
          echo "EKS public endpoint disabled (private-only)."
          exit 0
        fi
        sleep 10
      done
      echo "WARN: public endpoint still enabled after wait" >&2
      exit 1
    EOT
  }

  depends_on = [
    # App (과제 9.3)
    kubernetes_deployment_v1.wsc,
    kubernetes_service_v1.wsc,
    # Addons / LB Controller + TargetGroupBinding (과제 12.2)
    helm_release.lb_controller,
    null_resource.book_tgb,
    # Logging - Fluent Bit (과제 10)
    helm_release.fluentbit,
    # Observability - Prometheus / Grafana + Addon LB (과제 11)
    helm_release.prometheus,
    helm_release.grafana,
    kubernetes_ingress_v1.addon,
  ]
}
