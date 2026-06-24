# ═══════════════════════════════════════════════════════════════
# Kubernetes - App (과제 9.3 ~ 9.6)
#   - Namespace: wsc / logging / monitoring
#   - ConfigMap: wsc-config (환경변수 중앙관리, 과제 9.5)
#   - Deployment: wsc-deploy / container wsc-cnt / replicas 2 (고가용성)
#   - ServiceAccount book-sa + Pod Identity (DynamoDB, 과제 9.4 IMDS 차단 대체)
#   - StorageClass: wsc-sc (EBS CSI, CMK, WaitForFirstConsumer)
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "wsc" {
  metadata { name = "wsc" }
  depends_on = [aws_eks_node_group.app]
}

resource "kubernetes_namespace_v1" "logging" {
  metadata { name = "logging" }
  depends_on = [aws_eks_node_group.addon]
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata { name = "monitoring" }
  depends_on = [aws_eks_node_group.monitoring]
}

# ── App Pod 의 DynamoDB 접근 (IRSA/Pod Identity, 노드 IAM 미사용) ──
resource "aws_iam_role" "book_app" {
  name = "wsc-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "book_app" {
  name = "DynamoKms"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = "book-sa"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "wsc"
  service_account = "book-sa"
  role_arn        = aws_iam_role.book_app.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# ── ConfigMap (환경변수, 과제 9.5) ──
resource "kubernetes_config_map_v1" "wsc" {
  metadata {
    name      = "wsc-config"
    namespace = kubernetes_namespace_v1.wsc.metadata[0].name
  }
  data = {
    AWS_REGION = local.region
    TABLE_NAME = local.table_name
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
  depends_on = [aws_eks_pod_identity_association.book, null_resource.build_push_book]
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
    kmsKeyId  = aws_kms_key.main.arn
  }
  depends_on = [aws_eks_addon.ebs_csi]
}
