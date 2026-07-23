############################
# 앱 배포 (2단계 flow 에서 누락됐던 setup.sh 복원)
#   - bastion 안 terraform apply 시 자동 실행된다 (docker/kubectl/helm 은 bastion 에 설치됨).
#   - book 이미지 빌드/푸시(2-2), namespace(4-4), LBC, book 배포, NetworkPolicy(4-5),
#     grafana(10-2), fluent-bit(10-1) 를 수행.
############################

resource "null_resource" "deploy_app" {
  triggers = {
    manifests   = sha1(join(",", [for f in fileset("${path.module}/k8s", "**") : filesha1("${path.module}/k8s/${f}")]))
    script      = filesha1("${path.module}/deploy-app.sh.tpl")
    dockerfile  = filemd5("${path.module}/application/Dockerfile")
    book_binary = filesha1("${path.module}/application/book-linux-amd64_v1.0.1")
    book_tg     = aws_lb_target_group.book.arn
    grafana_tg  = aws_lb_target_group.grafana.arn
    cluster     = aws_eks_cluster.cluster.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = templatefile("${path.module}/deploy-app.sh.tpl", {
      account_id     = local.account_id
      region         = local.region
      cluster_name   = aws_eks_cluster.cluster.name
      book_tg_arn    = aws_lb_target_group.book.arn
      grafana_tg_arn = aws_lb_target_group.grafana.arn
      oidc_id        = element(split("/", aws_eks_cluster.cluster.identity[0].oidc[0].issuer), 4)
      basedir        = path.module
    })
  }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_node_group.app,
    aws_lb_target_group.book,
    aws_lb_target_group.grafana,
    aws_lb_listener.http,
    aws_lb_listener_rule.grafana,
    aws_iam_role.book_app,
    aws_iam_role_policy.book_app_dynamodb,
    aws_iam_role.grafana,
    aws_iam_role_policy_attachment.grafana_cloudwatch,
    aws_iam_openid_connect_provider.eks,
    aws_eks_addon.vpc_cni,
    null_resource.aws_auth,
  ]
}
