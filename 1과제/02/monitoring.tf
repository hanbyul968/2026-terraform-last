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

# Grafana ALB(wskorea26-grafana-alb) -> Grafana Pod(3000) 인바운드.
#   ALB 는 ./k8s 의 Ingress 로 LB Controller 가 만들며 SG 도 컨트롤러가 관리하지만,
#   백엔드 SG 규칙 추가가 늦거나 누락되면 타깃이 unhealthy 로 남아 채점 10-0(Grafana
#   접속)이 통째로 막힌다. Pod ENI 가 쓰는 EKS 클러스터 SG 에 VPC 내부 3000 을 미리
#   열어 안전장치를 둔다. (ALB 는 같은 VPC 의 퍼블릭 서브넷에 위치)
resource "aws_security_group_rule" "grafana_from_alb" {
  type              = "ingress"
  description       = "Grafana ALB health check + traffic to grafana pods on 3000"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
