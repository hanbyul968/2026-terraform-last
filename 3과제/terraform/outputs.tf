output "endpoint" {
  description = "Submit this to grader (no path)"
  value       = "http://${aws_cloudfront_distribution.this.domain_name}"
}

output "alb_dns" {
  value = aws_lb.this.dns_name
}

output "ecr_repos" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "s3_bucket" {
  value = aws_s3_bucket.images.bucket
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}


# ---------------------------------------------------------------------------
# 파생 사이징 확인용 — apply 전에 plan 으로 값을 눈으로 검증한다.
# 인스턴스 타입을 바꿨을 때 의도대로 재계산되는지 여기서 확인할 수 있다.
# ---------------------------------------------------------------------------
output "sizing" {
  description = "인스턴스 타입에서 파생된 사이징 값 (타입 변경 시 자동 재계산)"
  value = {
    instance_type  = var.node_instance_type
    node_vcpu      = local.node_vcpu
    node_app_cpu_m = local.node_app_cpu_m
    node_max_pods  = local.node_max_pods_effective
    karpenter_cpu  = local.karpenter_cpu_limit_effective
    isolated_cpu   = local.karpenter_isolated_cpu_limit
    baseline_nodes = local.baseline_nodes_total
    baseline_ratio = local.baseline_cost_ratio
    isolated_apps  = local.isolated_apps
  }
}

output "apps" {
  description = "앱별 최종 적용 설정 (자동 발견 + override 결과)"
  value = {
    for n, a in local.apps : n => {
      path      = a.path
      node_port = a.node_port
      cpu_req   = "${a.cpu_request_m}m"
      cpu_limit = a.cpu_limit_m != null ? "${a.cpu_limit_m}m" : "none"
      replicas  = "${a.min_replicas}-${a.max_replicas}"
      hpa_cpu   = a.hpa_target_cpu
      isolate   = a.isolate
      cache_ttl = a.cache_ttl
      needs_db  = a.needs_db
      needs_s3  = a.needs_s3
    }
  }
}
