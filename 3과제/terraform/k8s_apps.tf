# ---------------------------------------------------------------------------
# 앱 워크로드 — local.apps 를 for_each 로 돌려 앱마다 동일한 구조를 생성한다.
#
# 이전 버전은 user/product/stress 3개를 각각 250줄씩 복붙해 두었다. 대회날 앱이
# 바뀌면 블록을 새로 써야 하고, 한쪽만 고치는 실수가 나기 쉬웠다.
# 지금은 앱이 몇 개든, 이름이 무엇이든 이 파일은 그대로 둔다 (apps.tf 의 맵만 바뀐다).
#
# 앱별로 달라지는 것은 전부 local.apps[name] 에 들어 있다:
#   경로/포트, CPU·메모리 request/limit, HPA 목표·범위, DB/S3 사용, 격리 여부, 캐시
# ---------------------------------------------------------------------------

locals {
  ecr_url = { for k, v in aws_ecr_repository.this : k => v.repository_url }

  # 격리 노드풀 식별자 (karpenter.tf 의 NodePool 과 공유)
  isolated_taint_key = "workload-isolated"
  isolated_label_key = "workload"
  isolated_label_val = "isolated"
}

# ---------- ServiceAccount ----------
# S3 쓰기가 필요한 앱만 IRSA 역할을 붙인다 (iam.tf 가 앱별로 역할을 만든다).
resource "kubernetes_service_account" "app" {
  for_each = local.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = each.value.needs_s3 ? {
      "eks.amazonaws.com/role-arn" = aws_iam_role.app_s3[each.key].arn
    } : {}
  }
}

# ---------- Deployment ----------
resource "kubernetes_deployment" "app" {
  for_each = local.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    # HPA 가 실제 replica 수를 관리한다. 여기 값은 최초 생성 시점의 시작값이며,
    # ignore_changes 로 HPA 와 terraform 이 서로 싸우지 않게 한다.
    replicas = each.value.min_replicas

    selector { match_labels = { app = each.key } }

    # max_surge=1 / max_unavailable=0 은 타협 불가다. 반대로 두면(0/1) 롤링 업데이트가
    # 구 파드를 먼저 지워 가용 레플리카가 desired 아래로 내려가고, ALB 가
    # deregistration_delay 동안 draining 타깃을 들고 있어 부하 중이면 504 가 된다.
    # (실측: 0/1 로 바꾼 회차에서 504 발생 → 가용성 점수 직접 손실)
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = { app = each.key }
        # DB 엔드포인트가 바뀌면 파드 템플릿이 바뀌어 롤링 재배포된다.
        # env_from(Secret) 은 실행 중 파드에 자동 반영되지 않으므로 이 어노테이션이
        # 없으면 apply 후에도 옛 MYSQL_HOST 를 계속 써서 DNS 실패로 500 을 쏟는다.
        annotations = each.value.needs_db ? { "wsi/db-host" = local.db_host } : {}
      }

      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.app[each.key].metadata[0].name

        # ── 배치 전략 ────────────────────────────────────────────────
        # isolate=true 인 앱은 전용 노드풀(taint 걸림)로만 간다.
        # CPU 폭식 앱을 지연 민감 앱과 섞으면 폭식 앱이 CPU 를 다 먹어 민감 앱의
        # 응답이 SLO 를 넘긴다. taint/toleration 이 커널 스케줄러 수준에서 이를 막는다.
        node_selector = each.value.isolate ? { (local.isolated_label_key) = local.isolated_label_val } : {}

        dynamic "toleration" {
          for_each = each.value.isolate ? [1] : []
          content {
            key      = local.isolated_taint_key
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }
        }

        # 격리 대상이 아닌 앱은 관리형 NG 노드를 '선호'한다.
        # Karpenter 노드는 consolidation 회수 대상이라 언제든 사라지므로 베이스라인
        # 레플리카의 정착지로는 desired 고정인 NG 노드가 맞다.
        # required 가 아니라 preferred 인 이유: 강제하면 스케일아웃 파드가 NG 에
        # 자리가 없을 때 Pending 이 되어 가용성을 깎는다.
        dynamic "affinity" {
          for_each = each.value.isolate ? [] : [1]
          content {
            node_affinity {
              preferred_during_scheduling_ignored_during_execution {
                weight = 100
                preference {
                  match_expressions {
                    key      = "eks.amazonaws.com/nodegroup"
                    operator = "Exists"
                  }
                }
              }
            }
          }
        }

        # AZ 분산은 '선호'로 둔다. DoNotSchedule 로 강제하면 한쪽 AZ 가 꽉 찰 때
        # 반대쪽으로 못 가고 Pending 이 되어 가용성을 깎는다. 채점은 AZ 장애를
        # 측정하지 않으므로 Pending 위험을 감수할 이유가 없다.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector { match_labels = { app = each.key } }
        }

        # 노드 단위 분산. maxSkew=2 인 이유: 1 로 두면 Karpenter 가 노드를 통합할 수
        # 없다(파드를 남은 노드로 옮기면 노드당 2개가 되어 skew=1 위반 → 통합 계획
        # 자체가 안 세워짐). 실측 로그에 "preferred TopologySpreadConstraint which can
        # prevent consolidation" 이 반복되며 빈 노드가 회수되지 않아 비용이 올랐다.
        # match_label_keys=pod-template-hash 는 롤아웃 중 구 파드가 계산을 오염시켜
        # 신 파드가 한쪽으로 몰리는 문제를 막는다.
        topology_spread_constraint {
          max_skew           = 2
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector { match_labels = { app = each.key } }
        }

        container {
          name              = each.key
          image             = "${local.ecr_url[each.key]}:${local.app_image_tags[each.key]}"
          image_pull_policy = "IfNotPresent"

          port { container_port = each.value.container_port }

          # DB 자격증명은 필요한 앱에만 주입한다.
          dynamic "env_from" {
            for_each = each.value.needs_db ? [1] : []
            content {
              secret_ref { name = kubernetes_secret.db.metadata[0].name }
            }
          }

          # S3 버킷/리전은 모든 앱에 넣어도 무해하고, 앱이 바뀌어 S3 를 쓰기 시작해도
          # 코드 수정 없이 동작한다.
          env_from {
            config_map_ref { name = kubernetes_config_map.s3.metadata[0].name }
          }

          # 앱별 추가 환경변수 (대회날 새 키 요구 시 tfvars 로 대응)
          dynamic "env" {
            for_each = each.value.env
            content {
              name  = env.key
              value = env.value
            }
          }

          resources {
            # request 는 실측 사용량 기준. 과대 설정하면 HPA 사용률이 희석되어
            # 스케일아웃이 안 되고(성능↓), bin-packing 이 한가한 노드를 늘린다(비용↑).
            requests = {
              cpu    = "${each.value.cpu_request_m}m"
              memory = each.value.memory_request
            }
            # CPU limit 은 기본으로 두지 않는다(불필요한 스로틀링 방지).
            # 단 CPU 폭식 앱에는 limit 을 걸어 노드 독점을 막는다 → cpu_limit_pct 사용.
            limits = merge(
              { memory = each.value.memory_limit },
              each.value.cpu_limit_m != null ? { cpu = "${each.value.cpu_limit_m}m" } : {}
            )
          }

          readiness_probe {
            http_get {
              path = each.value.healthcheck_path
              port = each.value.container_port
            }
            period_seconds    = 5
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = each.value.healthcheck_path
              port = each.value.container_port
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }

  # HPA 가 replicas 를 관리하므로 terraform 은 그 필드를 무시한다.
  # (없으면 apply 마다 replicas 를 min 으로 되돌려 부하 중 용량이 꺾인다)
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  wait_for_rollout = false

  depends_on = [
    kubernetes_job.db_init,
    null_resource.build_push,
    aws_eks_node_group.main,
  ]
}

# ---------- Service (NodePort) ----------
resource "kubernetes_service" "app" {
  for_each = local.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = each.key }
    port {
      port        = 80
      target_port = each.value.container_port
      node_port   = each.value.node_port
    }
    type = "NodePort"
  }
}

# ---------- HPA ----------
resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  for_each = local.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_replicas = each.value.min_replicas
    max_replicas = each.value.max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.app[each.key].metadata[0].name
    }

    behavior {
      scale_up {
        # 계단식 트래픽의 초기 손실을 줄이기 위해 즉시 확장한다.
        # 비용 상한은 max_replicas 와 Karpenter nodepool limit 이 담당한다.
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
      }
      scale_down {
        # 성능 우선: 축소를 아주 느리게 한다.
        # 짧은 창(90~120s)은 부하가 잠깐 내려갈 때 파드를 줄였다가 곧바로 다시 늘리는
        # 진동을 만든다. 그 사이 새 파드가 Ready 될 때까지(+노드 부팅 시 60~90s) 남은
        # 파드에 부하가 몰려 지연이 튄다. 실측: user p50 126ms -> 369ms 진동.
        # 5분 창 + 회당 25% 면 부하 구간 내에서는 사실상 줄지 않고, 부하가 끝난 뒤에만 준다.
        stabilization_window_seconds = 300
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 25
          period_seconds = 60
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type = "Utilization"
          # 사용률 = 실사용 / request. request 가 실측에 맞아야 이 목표가 의미를 갖는다.
          average_utilization = each.value.hpa_target_cpu
        }
      }
    }
  }

  depends_on = [aws_eks_addon.metrics_server]
}
