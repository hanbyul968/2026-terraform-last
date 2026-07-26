locals {
  name = var.project
  # S3 버킷 이름 prefix — bucket_prefix 지정 시 그 값, 아니면 project. (전역 고유용)
  bucket_prefix = var.bucket_prefix != "" ? var.bucket_prefix : var.project
  tags = {
    Project = var.project
  }
  account_id   = data.aws_caller_identity.current.account_id
  oidc_arn     = aws_iam_openid_connect_provider.eks.arn
  oidc_url     = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  profile_args = var.aws_profile != "" ? ["--profile", var.aws_profile] : []
  exec_env     = var.aws_profile != "" ? { AWS_PROFILE = var.aws_profile } : {}

  # 클러스터 이름은 항상 정적으로 알 수 있으므로 provider exec 에 그대로 사용.
  eks_cluster_name = "${local.name}-cluster"
  # k8s_provider_ready=false 면 아직 생성 전이므로 더미 값을 사용(연결은 실제 apply 시에만 발생).
  eks_host = var.k8s_provider_ready ? aws_eks_cluster.this.endpoint : "https://localhost"
  eks_ca   = var.k8s_provider_ready ? base64decode(aws_eks_cluster.this.certificate_authority[0].data) : ""

  # ---------- 유효 API 경로 (단일 소스: WAF scope-down + ALB deny_direct 가 공용) ----------
  # 기본: <api_prefix>/<앱이름> (앱 목록 = alb.tf local.node_ports 의 키).
  # 경로가 앱 이름과 달라지면 var.api_paths_override 로 통째로 교체.
  api_paths = length(var.api_paths_override) > 0 ? var.api_paths_override : [
    for k in sort(keys(local.node_ports)) : "${var.api_prefix}/${k}"
  ]
  # 관리형 룰 scope-down: 유효 API 경로만 정확히 매칭 (미정의 경로는 WAF 통과 → ALB 404)
  api_path_regex = "^(${join("|", local.api_paths)})$"
  # 커스텀 차단 룰 적용 범위: 제공하는 모든 유효 엔드포인트 (API + healthcheck + images).
  # 미정의 경로는 커스텀 룰도 건너뛰어 404 유지 (스펙: 제공 API 외 = 404, 비정상 = 403).
  waf_block_scope_regex = "^(${join("|", local.api_paths)}|${var.healthcheck_path}|${var.images_prefix}/.*)$"
}
