# PodDisruptionBudget — Karpenter 가 노드를 회수(drain)할 때 앱이 통째로 끊기지 않게 한다.
#
# 배경: Karpenter 는 consolidation 으로 노드를 자발적으로 비운다(voluntary disruption).
# 이때 PDB 가 없으면 해당 노드의 파드를 제약 없이 evict 하므로, replica 가 1 이거나
# 여러 replica 가 같은 노드에 몰려 있으면 그 앱이 순간적으로 0개가 되어 서비스가 끊긴다.
# (실측: user/product/stress 파드 3개가 모두 한 노드에 스케줄된 상태였다)
#
# minAvailable = 1 → 항상 최소 1개는 살아 있어야 evict 가 허용된다.
#  - replica 가 2 이상이면: 한 번에 1개씩만 빠지며 롤링되어 무중단으로 노드가 비워진다.
#  - replica 가 1 이면: evict 가 아예 차단되어 Karpenter 가 그 노드를 회수하지 않는다.
#    → 서비스는 안 끊기지만 노드가 남는다. 비용까지 챙기려면 min_replicas 를 2 로 올려
#      아래 hostname spread 와 함께 두 노드에 나눠 두는 것이 정답이다.
#
# ⚠ PDB 는 자발적 중단(drain/consolidation)만 막는다. 노드 강제 종료·하드웨어 장애 같은
#   비자발적 중단은 막지 못하므로, 그 방어는 replica 수 + 노드 분산이 담당한다.
resource "kubernetes_pod_disruption_budget_v1" "app" {
  for_each = local.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = { app = each.key }
    }
  }

  depends_on = [kubernetes_namespace.app]
}
