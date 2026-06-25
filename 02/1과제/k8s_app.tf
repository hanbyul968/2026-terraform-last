# ═══════════════════════════════════════════════════════════════
# Kubernetes - book Application  (과제 5/8)
#   - Namespace: wskorea26 (논리적 분리)
#   - Deployment: book 컨테이너(이미지 stable), replicas 2(고가용성), node-type=app
#   - 환경변수(AWS_REGION/TABLE_NAME)는 ConfigMap (Reference02)
#   - DynamoDB 접근은 Pod Identity (노드 IAM 미사용, 최소권한)
#   - Service(ClusterIP) wskorea26-book-svc : 80 -> 8080, book TG 바인딩 대상
# 채점 5-3: wskorea26 ns 존재, app pod 는 node-type=app 노드
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "app" {
  metadata { name = local.namespace }
  depends_on = [aws_eks_node_group.app]
}

# book Pod 의 DynamoDB 접근 (Pod Identity)
resource "aws_iam_role" "book_app" {
  name = "wskorea26-book-app-role"
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
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = "wskorea26-book-sa"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.namespace
  service_account = kubernetes_service_account_v1.book.metadata[0].name
  role_arn        = aws_iam_role.book_app.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# 환경변수 ConfigMap (Reference02: AWS_REGION, TABLE_NAME)
resource "kubernetes_config_map_v1" "book" {
  metadata {
    name      = "wskorea26-book-config"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    AWS_REGION = local.region
    TABLE_NAME = local.table_name
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
          image = local.image_url
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
  depends_on = [aws_eks_pod_identity_association.book, null_resource.build_push_book]
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
    kmsKeyId  = aws_kms_key.s3.arn
  }
  depends_on = [aws_eks_addon.ebs_csi]
}
