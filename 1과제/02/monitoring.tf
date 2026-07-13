# ═══════════════════════════════════════════════════════════════
# Monitoring  (과제 12)
#   이 과제의 모니터링 구성은 전부 Kubernetes/Helm 리소스이므로
#   ./k8s 스테이지(k8s/main.tf)로 이동했다.
#   이동 항목:
#     - kubernetes_namespace_v1.monitoring
#     - kubernetes_persistent_volume_claim_v1.prometheus / .grafana
#     - kubernetes_config_map_v1.dashboard
#     - helm_release.prometheus / helm_release.grafana
#   root(AWS) 에는 모니터링 관련 AWS 리소스가 없다.
# ═══════════════════════════════════════════════════════════════
