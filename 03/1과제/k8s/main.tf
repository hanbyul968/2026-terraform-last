# =============================================================================
# 03 1과제 — 2단계(k8s/helm) 스테이지
#   root(AWS) apply 가 끝난 뒤 실행한다. 클러스터/VPC/Subnet/ALB-SG 는 이름으로 data 조회.
#   포함: book Namespace/SA/ConfigMap/Deployment/Service/PDB/Ingress,
#         AWS LB Controller(helm), kube-prometheus-stack(helm)+dashboard,
#         Fluent Bit(helm)+SA, ALB 활성 대기(null), finalize(EKS private-only) (마지막).
# =============================================================================

data "aws_caller_identity" "current" {}

# root aws_vpc.this (Name 태그로 조회)
data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# root aws_security_group.alb (Name 태그로 조회) → ingress 의 ALB SG
data "aws_security_group" "alb" {
  filter {
    name   = "group-name"
    values = [var.alb_sg_name]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

# root aws_subnet.hub_* (Name 태그로 조회) → ingress 의 public subnet
data "aws_subnet" "hub_a" {
  filter {
    name   = "tag:Name"
    values = [var.hub_subnet_a_name]
  }
}

data "aws_subnet" "hub_b" {
  filter {
    name   = "tag:Name"
    values = [var.hub_subnet_b_name]
  }
}

locals {
  image_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repo}:${var.image_tag}"
}

# ═══════════════════════════════════════════════════════════════
# Kubernetes - Book App  (과제 8)
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "app" {
  metadata { name = var.app_namespace }
}

resource "kubernetes_namespace_v1" "obs" {
  metadata { name = var.obs_namespace }
}

# ── SA (Pod Identity 연결은 root 에서 SA 이름 문자열로 생성됨) ──
resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = var.sa_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

# ── ConfigMap (환경변수, 하드코딩 금지) : 이름 book-config ──
resource "kubernetes_config_map_v1" "book" {
  metadata {
    name      = "book-config"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    AWS_REGION = var.region
    TABLE_NAME = var.table_name
  }
}

# ── Deployment ──
resource "kubernetes_deployment_v1" "book" {
  metadata {
    name      = var.deploy_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "wsc2026-book" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "wsc2026-book" }
    }
    template {
      metadata {
        labels = { app = "wsc2026-book" }
      }
      spec {
        service_account_name = var.sa_name
        node_selector        = { "wsc2026/node" = "application" }

        # AZ 간 균등 분산 (채점 5-2: topology.kubernetes.io/zone)
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = { app = "wsc2026-book" }
          }
        }

        container {
          name  = "book"
          image = local.image_url
          port {
            container_port = 8080
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.book.metadata[0].name
            }
          }
          resources {
            requests = { cpu = "256m", memory = "512Mi" }
            limits   = { cpu = "256m", memory = "512Mi" }
          }
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            failure_threshold = 30
            period_seconds    = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds = 10
          }
        }
      }
    }
  }
}

# ── Service (동일 AZ 우선 라우팅으로 Cross-AZ 비용 절감) ──
resource "kubernetes_service_v1" "book" {
  metadata {
    name      = var.service_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "service.kubernetes.io/topology-mode" = "Auto"
    }
  }
  spec {
    selector = { app = "wsc2026-book" }
    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# ── PDB (최소 1 가용) ──
resource "kubernetes_pod_disruption_budget_v1" "book" {
  metadata {
    name      = var.pdb_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = { app = "wsc2026-book" }
    }
  }
}

# ── Ingress -> ALB(internet-facing) wsc2026-app-alb ──
resource "kubernetes_ingress_v1" "book" {
  metadata {
    name      = var.ingress_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"                              = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"                         = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name"                  = var.alb_name
      "alb.ingress.kubernetes.io/subnets"                             = "${data.aws_subnet.hub_a.id},${data.aws_subnet.hub_b.id}"
      "alb.ingress.kubernetes.io/security-groups"                     = data.aws_security_group.alb.id
      "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
      "alb.ingress.kubernetes.io/listen-ports"                        = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"                    = "/health"
      "alb.ingress.kubernetes.io/healthcheck-port"                    = "8080"
      # 잘못된 경로는 403 (채점 12 / CDN 외 직접 경로)
      "alb.ingress.kubernetes.io/actions.deny-403" = jsonencode({
        type = "fixed-response"
        fixedResponseConfig = {
          contentType = "application/json"
          statusCode  = "403"
          messageBody = "Forbidden"
        }
      })
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      http {
        # 실제 경로
        path {
          path      = "/v1/book"
          path_type = "Prefix"
          backend {
            service {
              name = var.service_name
              port { number = 8080 }
            }
          }
        }
        # 그 외 모든 경로 -> 403
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "deny-403"
              port { name = "use-annotation" }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.lb_controller, kubernetes_service_v1.book]
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller (helm)
#   IAM/Policy/Pod Identity 연결은 root 에서 생성됨.
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
    name  = "nodeSelector.wsc2026/node"
    value = "addon"
  }
}

# ═══════════════════════════════════════════════════════════════
# Observability — kube-prometheus-stack (helm) + Grafana dashboard
#   Grafana Pod Identity / IAM 은 root 에서 생성됨.
# ═══════════════════════════════════════════════════════════════

# Grafana 대시보드 (sidecar 자동 로드)
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = var.dashboard_name
    namespace = kubernetes_namespace_v1.obs.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wsc2026-grafana-dashboard.json" = file("${path.module}/wsc-eks-dashboard.json")
  }
}

resource "helm_release" "kps" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace_v1.obs.metadata[0].name

  values = [templatefile("${path.module}/kps-values.yaml.tftpl", {
    admin_password = var.grafana_admin_password
    region         = var.region
    log_group      = var.app_log_group
    dashboard_name = var.dashboard_name
  })]

  timeout = 900

  depends_on = [
    helm_release.lb_controller,
    kubernetes_config_map_v1.dashboard,
  ]
}

# ═══════════════════════════════════════════════════════════════
# Logging — Fluent Bit (helm) + SA
#   Fluent Bit Pod Identity / IAM / LogGroup 은 root 에서 생성됨.
# ═══════════════════════════════════════════════════════════════
resource "kubernetes_service_account_v1" "fluentbit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.obs.metadata[0].name
  }
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = kubernetes_namespace_v1.obs.metadata[0].name

  values = [templatefile("${path.module}/fluentbit-values.yaml.tftpl", {
    log_group = var.app_log_group
    region    = var.region
    sa_name   = kubernetes_service_account_v1.fluentbit.metadata[0].name
  })]

  depends_on = [
    helm_release.lb_controller,
  ]
}

# ═══════════════════════════════════════════════════════════════
# ingress 가 만든 ALB 가 active 가 될 때까지 대기 (root CloudFront origin 용)
# ═══════════════════════════════════════════════════════════════
resource "null_resource" "wait_alb" {
  triggers = { ingress = var.ingress_name }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = { REGION = var.region, ALB = var.alb_name }
    command     = <<-EOT
      set -euo pipefail
      for i in $(seq 1 60); do
        state=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB" --query "LoadBalancers[0].State.Code" --output text 2>/dev/null || true)
        if [ "$state" = "active" ]; then exit 0; fi
        sleep 15
      done
      echo "ALB $ALB not active in time" >&2
      exit 1
    EOT
  }
  depends_on = [kubernetes_ingress_v1.book]
}

# ═══════════════════════════════════════════════════════════════
# finalize: 모든 k8s/helm 적용 후 EKS public endpoint 끄기(private-only)
#   채점 4-1: endpointPublicAccess=False / endpointPrivateAccess=True
# ═══════════════════════════════════════════════════════════════
resource "null_resource" "private_only" {
  triggers = {
    cluster = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = var.region
      CLUSTER = var.cluster_name
    }
    command = <<-EOT
      set -euo pipefail
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

  # 폴더의 TERMINAL 리소스들 (k8s/helm/앱 적용이 전부 끝난 뒤 endpoint 를 닫는다)
  depends_on = [
    kubernetes_deployment_v1.book,
    kubernetes_service_v1.book,
    kubernetes_ingress_v1.book,
    kubernetes_pod_disruption_budget_v1.book,
    helm_release.lb_controller,
    helm_release.kps,
    helm_release.fluentbit,
    null_resource.wait_alb,
  ]
}
