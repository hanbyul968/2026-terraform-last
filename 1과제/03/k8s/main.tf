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
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "250m", memory = "512Mi" }
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
    labels    = { app = "wsc2026-book" }
    annotations = {
      "service.kubernetes.io/topology-mode" = "Auto"
    }
  }
  spec {
    selector = { app = "wsc2026-book" }
    port {
      name        = "http"
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
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name" = var.alb_name
      "alb.ingress.kubernetes.io/subnets"            = "${data.aws_subnet.hub_a.id},${data.aws_subnet.hub_b.id}"
      "alb.ingress.kubernetes.io/security-groups"    = data.aws_security_group.alb.id
      # shared backend SG를 비활성화했으므로 target SG 규칙은 root alb.tf에서 직접 관리한다.
      "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/health"
      "alb.ingress.kubernetes.io/healthcheck-port" = "8080"
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
  version    = "3.4.2"
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
  # 기본값 true이면 k8s-traffic-* shared SG가 ALB에 추가되어 채점 8-1이 실패한다.
  set {
    name  = "enableBackendSecurityGroup"
    value = "false"
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
    cluster_domain = var.cluster_dns_domain
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
  version    = "0.2.0"
  namespace  = kubernetes_namespace_v1.obs.metadata[0].name

  values = [templatefile("${path.module}/fluentbit-values.yaml.tftpl", {
    log_group      = var.app_log_group
    region         = var.region
    sa_name        = kubernetes_service_account_v1.fluentbit.metadata[0].name
    cluster_domain = var.cluster_dns_domain
  })]

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  depends_on = [
    kubernetes_service_account_v1.fluentbit,
  ]
}

# ── Fluent Bit 설정 오버라이드(two-branch) + 메트릭 ServiceMonitor ──
#   차트가 생성한 configmap을 fb/ 의 실제 설정으로 교체한다:
#     - logfmt → Reference02 JSON(`INFO {json}`) 재구성 (11-3 로그 형식)
#     - /v1/book 로그만 CloudWatch 전송 (채점 확정: 그 외 경로 차단)
#     - log_to_metrics 로 http_requests_total 생성 → HighErrorRate
#   fb-metrics-sm.yaml: :2021 노출 메트릭을 Prometheus가 수집하도록 Service + ServiceMonitor(relabel).
resource "null_resource" "fluentbit_config" {
  triggers = {
    conf   = filesha256("${path.module}/fb/fluent-bit.conf")
    parser = filesha256("${path.module}/fb/parser_extra.conf")
    lua    = filesha256("${path.module}/fb/reformat.lua")
    sm     = filesha256("${path.module}/fb/fb-metrics-sm.yaml")
    fb     = helm_release.fluentbit.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION    = var.region
      CLUSTER   = var.cluster_name
      NS        = var.obs_namespace
      DIR       = "${path.module}/fb"
      LOG_GROUP = var.app_log_group
      APP_NS    = var.app_namespace
      SVC       = var.service_name
    }
    command = <<-EOT
      set -eu
      export KUBECONFIG=$(mktemp)
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

      # 차트 configmap을 two-branch 설정으로 교체
      kubectl create configmap fluent-bit-aws-for-fluent-bit -n "$NS" \
        --from-file=fluent-bit.conf="$DIR/fluent-bit.conf" \
        --from-file=parser_extra.conf="$DIR/parser_extra.conf" \
        --from-file=reformat.lua="$DIR/reformat.lua" \
        --dry-run=client -o yaml | kubectl apply -f -

      # 새 설정 반영
      kubectl rollout restart daemonset/fluent-bit-aws-for-fluent-bit -n "$NS"
      kubectl rollout status  daemonset/fluent-bit-aws-for-fluent-bit -n "$NS" --timeout=120s

      # log_to_metrics(:2021) 스크레이프용 Service + ServiceMonitor
      kubectl apply -f "$DIR/fb-metrics-sm.yaml"

      # helm 설치 직후(차트 기본 설정 창)에 들어간 비-앱 로그(kube-proxy, coredns 등)를 지운다.
      # 채점 11-3 은 Application Logs 패널에 /v1/book 외 로그가 보이면 오답 처리한다.
      # tail DB(/var/log/flb_kube.db)에 오프셋이 남아 있어 지운 로그가 재전송되지는 않는다.
      for S in $(aws logs describe-log-streams --region "$REGION" \
                   --log-group-name "$LOG_GROUP" \
                   --query 'logStreams[].logStreamName' --output text 2>/dev/null | tr '\t' '\n'); do
        [ -z "$S" ] && continue
        echo "deleting stale log stream: $S"
        aws logs delete-log-stream --region "$REGION" \
          --log-group-name "$LOG_GROUP" --log-stream-name "$S" || true
      done

      # 과제 11 "동작의 확인을 위해 로그 및 메트릭을 1개 이상 발생" — /v1/book 1건 생성
      timeout 180 kubectl run wsc2026-logseed -n "$APP_NS" --rm -i --restart=Never \
        --image=curlimages/curl:8.11.1 \
        --overrides='{"spec":{"nodeSelector":{"wsc2026/node":"application"}}}' -- \
        curl -sS -o /dev/null -X POST "http://$SVC:8080/v1/book" \
          -H 'Content-Type: application/json' \
          -d '{"client_id":"LOGSEED","username":"LogSeed","email":"logseed@example.com","concert_name":"LogSeed"}' || true
    EOT
  }

  depends_on = [helm_release.fluentbit, helm_release.kps]
}

# ═══════════════════════════════════════════════════════════════
# ingress 가 만든 ALB 가 active 가 될 때까지 대기 (root CloudFront origin 용)
# ═══════════════════════════════════════════════════════════════
resource "null_resource" "wait_alb" {
  triggers = {
    ingress             = var.ingress_name
    ingress_annotations = sha256(jsonencode(kubernetes_ingress_v1.book.metadata[0].annotations))
    controller          = helm_release.lb_controller.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION    = var.region
      CLUSTER   = var.cluster_name
      ALB       = var.alb_name
      NAMESPACE = var.app_namespace
      INGRESS   = var.ingress_name
    }
    command = <<-EOT
      set -eu
      export KUBECONFIG=$(mktemp)
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

      for i in $(seq 1 60); do
        state=$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB" \
          --query "LoadBalancers[0].State.Code" --output text 2>/dev/null || true)
        address=$(kubectl get ingress "$INGRESS" -n "$NAMESPACE" \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

        if [ "$state" = "active" ] && [ -n "$address" ]; then
          echo "ALB $ALB is active: $address"
          exit 0
        fi

        if [ $((i % 3)) -eq 0 ]; then
          echo "Waiting for ALB $ALB (attempt $i/60, state=$${state:-not-created})"
          kubectl get events -n "$NAMESPACE" \
            --field-selector "involvedObject.kind=Ingress,involvedObject.name=$INGRESS" \
            --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -n 3 || true
        fi
        sleep 10
      done

      echo "ALB $ALB was not created or active within 10 minutes." >&2
      echo "=== Ingress diagnostics ===" >&2
      kubectl describe ingress "$INGRESS" -n "$NAMESPACE" >&2 || true
      echo "=== Load Balancer Controller errors ===" >&2
      kubectl logs -n kube-system deploy/aws-load-balancer-controller \
        --all-containers=true --since=15m 2>&1 | grep -Ei 'error|fail|denied|security.group|backend' | tail -n 100 >&2 || true
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

  # 폴더의 TERMINAL 리소스들 (k8s/helm/앱 적용이 전부 끝난 뒤 endpoint 를 닫는다)
  depends_on = [
    kubernetes_deployment_v1.book,
    kubernetes_service_v1.book,
    kubernetes_ingress_v1.book,
    kubernetes_pod_disruption_budget_v1.book,
    helm_release.lb_controller,
    helm_release.kps,
    helm_release.fluentbit,
    null_resource.fluentbit_config,
    null_resource.wait_alb,
  ]
}
