# =============================================================================
# 02 1과제 — 2단계(k8s/helm) 스테이지
#   root(AWS) apply 가 끝난 뒤 실행한다. 클러스터/ALB/VPC/KMS 는 이름으로 data 조회.
#   포함:
#     - book Namespace/SA/ConfigMap/Deployment/Service (app 노드)
#     - StorageClass(EBS CSI + s3 CMK)
#     - AWS LB Controller(helm) + TargetGroupBinding(kubectl)
#     - monitoring: PVC×2, Grafana dashboard CM, prometheus/grafana(helm)
#     - logging: Namespace/SA + aws-for-fluent-bit(helm)
#   root 가 만든 AWS 리소스(EKS/노드그룹/ALB/TG/IAM/PodIdentity/LogGroup/KMS)는
#   여기서 data 또는 var 로만 참조한다. (root 관리 리소스에 대한 depends_on 없음)
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

# EBS StorageClass 볼륨 암호화용 s3/general CMK (alias 로 조회)
data "aws_kms_key" "s3" {
  key_id = var.kms_s3_alias
}

# IRSA: root 에서 만든 역할 ARN 을 SA 어노테이션에 붙인다(Pod Identity 대신).
data "aws_iam_role" "book_app" {
  name = "wskorea26-book-app-role"
}
data "aws_iam_role" "fluentbit" {
  name = "wskorea26-fluentbit-role"
}
data "aws_iam_role" "lb_controller" {
  name = "wskorea26-lb-controller-role"
}

locals {
  # local.image_url(root) 과 동일: <acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
  image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.ecr_repo}:${var.image_tag}"
}

# ═══════════════════════════════════════════════════════════════
# Kubernetes - book Application  (k8s_app.tf 에서 이동)
# ═══════════════════════════════════════════════════════════════
resource "kubernetes_namespace_v1" "app" {
  metadata { name = var.namespace }
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name        = "wskorea26-book-sa"
    namespace   = kubernetes_namespace_v1.app.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = data.aws_iam_role.book_app.arn }
  }
}

# 환경변수 ConfigMap (Reference02: AWS_REGION, TABLE_NAME)
resource "kubernetes_config_map_v1" "book" {
  metadata {
    name      = "wskorea26-book-config"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    AWS_REGION = var.region
    TABLE_NAME = var.table_name
    TZ         = "Asia/Seoul" # created_at KST(+09:00) 기록 (Reference03, 채점 9-2)
  }
}

resource "kubernetes_deployment_v1" "book" {
  metadata {
    name      = "wskorea26-book"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "wskorea26-book" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "wskorea26-book" }
    }
    template {
      metadata {
        labels = { app = "wskorea26-book" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.book.metadata[0].name
        node_selector        = { "node-type" = "app" }
        container {
          name  = "book"
          image = local.image
          port {
            container_port = 8080
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.book.metadata[0].name
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

# book Service (TargetGroupBinding 대상). port 80 -> 8080
resource "kubernetes_service_v1" "book" {
  metadata {
    name      = "wskorea26-book-svc"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    selector = { app = "wskorea26-book" }
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }

  depends_on = [null_resource.wait_lbc_webhook]
}

# StorageClass (모니터링 PV 용, EBS CSI + CMK)
resource "kubernetes_storage_class_v1" "ebs" {
  metadata {
    name = "wskorea26-sc"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = data.aws_kms_key.s3.arn
  }
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller (helm) + TargetGroupBinding  (alb.tf 에서 이동)
#   IAM/PodIdentity(aws-load-balancer-controller SA) 는 root 에서 생성됨.
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
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.aws_iam_role.lb_controller.arn
  }
  # addon 노드그룹에 스케줄
  set {
    name  = "nodeSelector.node-type"
    value = "addon"
  }
}

# LB Controller 웹훅이 Ready(엔드포인트 보유)될 때까지 대기.
#   helm 설치 직후엔 webhook(mservice.elbv2.k8s.aws) 엔드포인트가 잠시 비어 있어,
#   그 사이 Service(book/prometheus/grafana) 생성 시 "no endpoints available for service
#   aws-load-balancer-webhook-service" 로 실패한다.
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

# book Service -> book TG 바인딩 (TargetGroupBinding CRD)
resource "null_resource" "book_tgb" {
  triggers = {
    tg = data.aws_lb_target_group.book.arn
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = var.region
      CLUSTER = var.cluster_name
      TG_ARN  = data.aws_lb_target_group.book.arn
      NS      = var.namespace
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
        echo "  name: wskorea26-book-tgb"
        echo "  namespace: $NS"
        echo "spec:"
        echo "  serviceRef:"
        echo "    name: wskorea26-book-svc"
        echo "    port: 80"
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
  depends_on = [helm_release.lb_controller, kubernetes_service_v1.book]
}

# ═══════════════════════════════════════════════════════════════
# Monitoring  (monitoring.tf 에서 이동) — 과제 12
# ═══════════════════════════════════════════════════════════════
resource "kubernetes_namespace_v1" "monitoring" {
  metadata { name = "monitoring" }
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus" {
  metadata {
    name      = "wskorea26-prometheus-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ebs.metadata[0].name
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "grafana" {
  metadata {
    name      = "wskorea26-grafana-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ebs.metadata[0].name
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

# Grafana 대시보드 (sidecar 자동 로드)
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = "wskorea26-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wskorea26-dashboard.json" = file("${path.module}/wskorea26-dashboard.json")
  }
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/prometheus-values.yaml.tftpl", {
    pvc_name = kubernetes_persistent_volume_claim_v1.prometheus.metadata[0].name
  })]

  depends_on = [
    kubernetes_storage_class_v1.ebs,
    null_resource.wait_lbc_webhook,
  ]
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/grafana-values.yaml.tftpl", {
    pvc_name       = kubernetes_persistent_volume_claim_v1.grafana.metadata[0].name
    admin_user     = var.grafana_admin_user
    admin_password = var.grafana_admin_password
    ds_url         = "http://prometheus-server.monitoring.svc.cluster.local"
  })]

  depends_on = [
    helm_release.prometheus,
    kubernetes_config_map_v1.dashboard,
    null_resource.wait_lbc_webhook,
  ]
}

# ═══════════════════════════════════════════════════════════════
# Logging  (logging.tf 에서 이동) — 과제 12
#   LogGroup/IAM/PodIdentity(fluent-bit SA) 는 root 에서 생성됨.
# ═══════════════════════════════════════════════════════════════
resource "kubernetes_namespace_v1" "logging" {
  metadata { name = "logging" }
}

resource "kubernetes_service_account_v1" "fluentbit" {
  metadata {
    name        = "fluent-bit"
    namespace   = kubernetes_namespace_v1.logging.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" = data.aws_iam_role.fluentbit.arn }
  }
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [templatefile("${path.module}/fluentbit-values.yaml.tftpl", {
    log_group = var.log_group
    region    = var.region
    sa_name   = kubernetes_service_account_v1.fluentbit.metadata[0].name
  })]

  depends_on = [null_resource.wait_lbc_webhook]
}
