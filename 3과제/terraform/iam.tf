# IRSA — S3 쓰기가 필요한 앱마다 역할을 만든다 (local.s3_apps = needs_s3 인 앱).
# 이전에는 "product" 가 하드코딩되어 있어, 대회날 이미지 업로드 담당 앱 이름이
# 바뀌면 iam.tf / s3.tf / k8s_apps.tf 를 모두 고쳐야 했다.
# 지금은 tfvars 에서 apps = { <앱이름> = { needs_s3 = true } } 만 지정하면 된다.

data "aws_iam_policy_document" "app_s3_assume" {
  for_each = local.s3_apps

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${kubernetes_namespace.app.metadata[0].name}:${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_s3" {
  for_each           = local.s3_apps
  name               = "${local.name}-${each.key}-app"
  assume_role_policy = data.aws_iam_policy_document.app_s3_assume[each.key].json
}

resource "aws_iam_policy" "app_s3" {
  for_each = local.s3_apps
  name     = "${local.name}-${each.key}-app-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_s3" {
  for_each   = local.s3_apps
  role       = aws_iam_role.app_s3[each.key].name
  policy_arn = aws_iam_policy.app_s3[each.key].arn
}
