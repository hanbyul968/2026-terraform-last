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
        # isolate=true 인 앱은 전용(taint 걸린) 노드를 '선호'한다.
        #
        # nodeSelector(하드)로 강제하면 안 되는 이유(실측): 전용 노드에만 뜰 수 있으므로
        # 부하가 전혀 없는 유휴 상태에서도 Karpenter 노드가 최소 1대 계속 남는다.
        # (stress 파드가 격리 노드를 붙잡아 t3.medium 2대가 유휴에도 유지됐다)
        # 정상 동작은 '부하 없으면 관리형 NG 최소 노드만' 이다.
        #
        # toleration + preferred affinity 조합이면:
        #   유휴  → 전용 노드가 없으니 NG 노드로 내려온다 → Karpenter 노드 전부 회수(0대)
        #   부하  → HPA 가 파드를 늘리고 NG(max_size 고정)가 꽉 차면 스케줄 불가 →
        #           Karpenter 가 전용 노드를 띄우고, preferred 가 그쪽으로 끌어당긴다
        # 즉 CPU 폭식 앱은 부하 구간에서만 전용 노드로 분리된다.
        #
        # isolate_hard=true 로 주면 예전처럼 전용 노드에만 뜬다(유휴 노드 1대는 감수).
        # user 성능이 다시 무너지면 그 쪽으로 되돌린다.
        node_selector = (each.value.isolate && each.value.isolate_hard) ? { (local.isolated_label_key) = local.isolated_label_val } : {}

        dynamic "toleration" {
          for_each = each.value.isolate ? [1] : []
          content {
            key      = local.isolated_taint_key
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }
        }

        # 모든 앱이 관리형 NG 노드를 '선호'한다 (격리 앱도 포함).
        #
        # 격리 앱이 전용 노드를 선호하게 만들면 안 된다(실측): 전용 노드가 한 번 뜨면
        # 유휴 상태에서도 파드가 계속 그 노드를 고르므로 노드가 비워지지 않고,
        # 결국 Karpenter 가 회수하지 못해 유휴에도 격리 노드가 남는다(자기 유지 상태).
        #
        # NG 를 선호하게 두면:
        #   유휴 → NG 에 자리가 있으니 stress 도 NG 로 → 격리 노드 비워짐 → 회수(0대)
        #   부하 → NG(max_size 고정)가 꽉 차 Pending → Karpenter 가 전용 노드 생성
        #          (격리 풀 weight=10 이라 taint 를 tolerate 하는 격리 앱이 그쪽으로 간다)
        # 즉 '전용 노드로 유도'는 affinity 가 아니라 NodePool weight + taint 가 담당한다.
        affinity {
          node_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 50
              preference {
                match_expressions {
                  key      = "eks.amazonaws.com/nodegroup"
                  operator = "Exists"
                }
              }
            }
          }

          # 서로 다른 앱은 같은 노드를 피한다 (선호, 강제 아님).
          #
          # 목적: 부하가 커질수록 앱이 자연히 노드 단위로 분리된다.
          #   유휴  → 노드가 NG 2대뿐이라 3개 앱이 어쩔 수 없이 같이 앉는다(노드 최소 유지)
          #   부하  → HPA 가 파드를 늘리고 Karpenter 가 노드를 추가하면, 이 선호가
          #           앱마다 다른 노드로 밀어낸다 → CPU 폭식 앱이 지연 민감 앱과 분리된다
          #
          # 왜 이 방식인가: 전용 노드풀 + taint 로 격리하면 '어느 앱이 폭식인지' 미리
          # 지정해야 하고(대회날 앱이 바뀌면 무용지물), 유휴에도 전용 노드가 남는다.
          # 안티어피니티는 앱 이름을 몰라도 성립하고, 부하량에 따라 자동으로 강해진다.
          #
          # weight 100 vs 위 node_affinity 50: 노드 분리를 NG 선호보다 우선한다.
          # ScheduleAnyway 성격(preferred)이라 자리가 없으면 그냥 같이 앉으므로
          # Pending 으로 가용성을 깎지 않는다.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app"
                    operator = "NotIn"
                    values   = [each.key]
                  }
                }
              }
            }
          }
        }

        # AZ 분산은 '선호'로 둔다. DoNotSchedule 로 강제하면 한쪽 AZ 가 꽉 찰 때
        # 반대쪽으로 못 가고 Pending 이 되어 가용성을 깎는다. 채점은 AZ 장애를
        # 측정하지 않으므로 Pending 위험을 감수할 이유가 없다.
        #
        # ⚠ 격리 앱(isolate=true)에는 이 제약을 걸지 않는다. Karpenter 는 선호(ScheduleAnyway)
        #   제약조차 통합을 막는 요소로 취급한다. 실측 로그:
        #     "pod(s) have a preferred TopologySpreadConstraint which can prevent consolidation"
        #   stress 파드 2개가 AZ 2곳에 1개씩 흩어진 상태에서, 한 노드로 모으면 둘 다 같은
        #   AZ 가 되어 zone maxSkew=1 을 위반하므로 통합 계획이 세워지지 않았다.
        #   그 결과 t3.medium 2대가 파드 1개씩만 얹고 계속 남았다.
        #   격리 앱은 지연 민감하지 않고 가용성은 레플리카 수로 확보되므로 AZ 분산을 포기한다.
        dynamic "topology_spread_constraint" {
          for_each = each.value.isolate ? [] : [1]
          content {
            max_skew           = 1
            topology_key       = "topology.kubernetes.io/zone"
            when_unsatisfiable = "ScheduleAnyway"
            match_label_keys   = ["pod-template-hash"]
            label_selector { match_labels = { app = each.key } }
          }
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
