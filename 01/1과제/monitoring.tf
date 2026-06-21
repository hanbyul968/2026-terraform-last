############################
# kube-prometheus-stack (namespace: prometheus)
#   - scrape/eval 15s, port 9090
#   - addon 노드에서 구동
#   - RuleGroup 'book' : BookPodNotRunning / BokPodCrashLooping / BookPodNotReady
############################
resource "helm_release" "kps" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "prometheus"
  create_namespace = true

  values = [yamlencode({
    # 불필요 컴포넌트 비활성
    grafana      = { enabled = false }
    alertmanager = { enabled = false }

    prometheusOperator = {
      nodeSelector = { node = "addon" }
      admissionWebhooks = {
        patch = { nodeSelector = { node = "addon" } }
      }
    }

    "kube-state-metrics" = {
      nodeSelector = { node = "addon" }
    }

    prometheus = {
      prometheusSpec = {
        scrapeInterval     = "15s"
        evaluationInterval = "15s"
        nodeSelector       = { node = "addon" }
        # 차트 외부 PrometheusRule 도 선택되도록
        ruleSelectorNilUsesHelmValues           = false
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }

    # RuleGroup 'book'
    additionalPrometheusRulesMap = {
      "book" = {
        groups = [{
          name = "book"
          rules = [
            {
              alert       = "BookPodNotRunning"
              expr        = "kube_pod_status_phase{namespace=\"book\", pod=~\"book-.*\", phase=\"Running\"} == 0"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is not in Running phase" }
            },
            {
              alert       = "BokPodCrashLooping"
              expr        = "increase(kube_pod_container_status_restarts_total{namespace=\"book\", pod=~\"book-.*\"}[5m]) > 2"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is crash looping" }
            },
            {
              alert       = "BookPodNotReady"
              expr        = "kube_pod_status_ready{namespace=\"book\", condition=\"true\", pod=~\"book-.*\"} == 0"
              for         = "30s"
              labels      = { severity = "critical" }
              annotations = { summary = "Book pod is not Ready" }
            }
          ]
        }]
      }
    }
  })]

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_addon.coredns,
  ]
}
