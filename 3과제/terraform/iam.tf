# IRSA for product app — needs S3 PutObject
data "aws_iam_policy_document" "product_app_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${kubernetes_namespace.app.metadata[0].name}:product"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "product_app" {
  name               = "${local.name}-product-app"
  assume_role_policy = data.aws_iam_policy_document.product_app_assume.json
}

resource "aws_iam_policy" "product_app_s3" {
  name = "${local.name}-product-app-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "product_app_s3" {
  role       = aws_iam_role.product_app.name
  policy_arn = aws_iam_policy.product_app_s3.arn
}
