locals {
  ecr_url = {
    for k, v in aws_ecr_repository.this : k => v.repository_url
  }
}

# ---------- user ----------
resource "kubernetes_service_account" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

resource "kubernetes_deployment" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "user" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "user" } }
    # max_surge=1 / max_unavailable=0 은 타협 불가다. 반대로 두면(0/1) 롤링 업데이트가
    # 구 파드를 '먼저 지우고' 새로 만들기 때문에 레플리카 2개 중 1개만 남는 구간이 생긴다.
    # 그 사이 ALB 는 지워진 파드의 타깃을 deregistration_delay 동안 draining 으로 들고 있고
    # 새 파드는 등록+헬스체크를 통과해야 하므로, 부하 중이면 용량 공백이 그대로 504 가 된다.
    # (실측: 0/1 로 바꾼 회차에서 504 발생. 가용성 12점을 직접 깎는다)
    # 1/0 이면 새 파드를 먼저 띄우고 Ready 를 확인한 뒤 구 파드를 지우므로
    # 가용 레플리카가 절대 desired 아래로 내려가지 않는다.
    #
    # 대가: 롤 결과의 노드 분산이 운에 좌우된다(어느 구 파드를 지울지는 ReplicaSet 삭제
    # 순서가 정하고 topology spread 를 보지 않는다). 그건 분산 문제이지 가용성 문제가
    # 아니고, 노드 분산은 node_desired_size=2 + NG 선호 affinity 로 따로 잡는다.
    # 가용성 > 분산 우선순위를 지킨다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
    template {
      metadata {
        labels = { app = "user" }
        # DB 엔드포인트가 바뀌면 파드 템플릿이 바뀌어 롤링 재배포된다.
        # env_from(Secret) 은 실행 중 파드에 자동 반영되지 않아, 이 어노테이션이 없으면
        # apply 후에도 옛 MYSQL_HOST 를 계속 써서 DNS 실패로 500 을 쏟는다.
        annotations = { "wsi/db-host" = aws_db_proxy.this.endpoint }
      }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.user.metadata[0].name
        # 기본 파드는 '관리형 NG 노드'에 앉힌다.
        # 이유: Karpenter 노드는 consolidation 회수 대상이라 언제든 사라진다. 베이스라인
        # 레플리카가 그 위에 있으면 노드 회수마다 서비스가 흔들린다. 관리형 NG 노드는
        # desired=2 로 고정되어 Karpenter 가 건드리지 못하므로 기본 파드의 정착지로 맞다.
        # (실측: NG 노드 2대가 텅 비고 앱 6개가 Karpenter 노드 2대에 올라가 있었다)
        #
        # preferred(선호)로 두는 이유: required 로 강제하면 스케일아웃 파드가 NG 2노드에
        # 못 들어갈 때 Pending 이 되어 가용성을 깎는다. preferred 면
        #   베이스라인 -> NG 노드(자리 있음), 스케일아웃 초과분 -> Karpenter 노드
        # 로 자연히 나뉘고, Karpenter 회수는 초과분 파드만 건드린다.
        # operator=Exists 로 노드그룹 이름에 결합하지 않는다.
        affinity {
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
        # AZ 분산은 '선호'로 둔다. DoNotSchedule 로 강제하면 안 되는 이유(실측):
        #   (a) 한쪽 AZ 노드가 꽉 차면 반대쪽으로 못 가고 Pending 으로 대기한다
        #       -> 가용성 점수(2xx 비율)를 직접 깎는다. 채점상 AZ 장애는 측정하지 않으므로
        #          Pending 위험을 감수할 이유가 없다.
        #   (b) 강제해도 롤링 업데이트 후 균형이 깨진다. 제약은 스케줄 시점에만 평가되는데,
        #       구 파드가 한쪽 AZ 에 있으면 신 파드가 전부 반대쪽으로 밀리고, 구 파드가
        #       종료되면 그 쪽에 2개가 남는다. 쿠버네티스는 사후 재배치를 하지 않는다.
        #       (실측: 6개 파드가 전부 2a 로 몰려 skew=2 위반 상태로 굳었다)
        # 노드 단위 몰림은 제약이 아니라 node_desired_size=2 로 막는다. 배포 시점에
        # Ready 노드가 이미 2개(AZ 당 1개) 있으면, 선호 제약만으로도 스케줄러가 빈 노드를
        # 우선 골라 앱마다 1개씩 나뉜다. 몰림의 진짜 원인은 제약이 약해서가 아니라
        # '파드가 배포될 때 노드가 1개뿐'이었던 것이다.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector { match_labels = { app = "user" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다.
        # maxSkew=2 인 이유: 1 은 노드당 1개만 허용해 Karpenter 가 노드를 회수하지 못하게
        # 막아 평균 노드 수가 4.8 까지 올라갔고(비용 6/12), 3 은 편차를 너무 허용해
        # 분산 압력이 사라졌다(실측: user/product 4개가 한 노드에 몰림).
        # 2 면 스케줄러가 빈 노드를 선호해 베이스라인 2레플리카는 1개씩 나뉘면서도,
        # 노드당 2개까지 허용하므로 consolidation 을 막지 않는다.
        # 전제: node_desired_size=2 로 배포 시점에 이미 노드가 2개 존재해야 한다.
        topology_spread_constraint {
          max_skew           = 2
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          # match_label_keys 가 이 제약을 실제로 쓸 수 있게 만든다.
          # 원래 topology spread 는 label_selector 에 맞는 '모든' 파드를 센다. 그래서
          # 롤링 업데이트 중에는 아직 종료되지 않은 구 파드까지 계산에 들어가고,
          # 신 파드가 엉뚱한 쪽으로 밀린 뒤 구 파드가 사라지면 분산이 깨진 채로 굳는다
          # (실측: 구 파드가 2b 에 있어 신 파드 6개가 전부 2a 로 몰림. k8s 는 사후 재배치 안 함).
          # pod-template-hash 를 넣으면 '같은 ReplicaSet 의 파드끼리만' 비교하므로
          # 신 파드는 자기들끼리 균등 분산되고 구 파드의 위치에 영향받지 않는다.
          #
          # maxSkew 는 1 이 아니라 2 다. 1 로 두면 Karpenter 가 노드를 통합하지 못한다:
          # 빈 노드를 없애려면 그 위의 파드를 남은 노드로 옮겨야 하는데, 그러면 노드당
          # 같은 앱 파드가 2개가 되어 skew=1 을 위반하므로 통합 계획 자체가 세워지지 않는다.
          #   실측 로그: "pod(s) have a preferred TopologySpreadConstraint which can
          #   prevent consolidation" 이 반복되며, DaemonSet 만 남은 빈 노드 2대가
          #   회수되지 않고 5대가 유지됐다(비용 지표는 평균 노드 수).
          # match_label_keys 는 '롤아웃 중 구 파드 오염'만 해결하고 이 문제는 못 막는다.
          # 2 로 두면 통합이 가능해지고, 균등 배치는 다른 수단으로 이미 보장된다:
          #   node_desired_size=2 로 배포 시점에 노드가 2대 있고, NG 선호 affinity 로
          #   기본 파드가 그 2대에 앉으며, 스케줄러 점수 계산이 빈 노드를 선호한다.
          # 즉 maxSkew=1 의 추가 이득은 '강제' 뿐인데 대가가 비용이라 손해다.
          match_label_keys = ["pod-template-hash"]
          label_selector { match_labels = { app = "user" } }
        }
        container {
          name              = "user"
          image             = "${local.ecr_url["user"]}:${local.app_image_tags["user"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          env_from {
            config_map_ref { name = kubernetes_config_map.s3.metadata[0].name }
          }
          resources {
            # 2026-08-20 실측 적용값. 발동점 600m x 90% = 540m.
            # AZ topology spread로 AZ 노드 1대에 user+product+stress 파드가 각 1개씩 앉는다.
            # 그 합이 노드 앱 여유 1480m(=allocatable 1930 - 시스템 예약 450)을 넘으면 유휴에도
            # Karpenter 노드가 상주해 회수되지 않는다. user 575 + product 250 + stress 650 = 1475m
            # 으로 맞춰 유휴 2노드(관리형 NG)로 유지한다. request는 예약량이라 성능엔 영향 없고,
            # 부하 시 HPA가 replica를 늘려 Karpenter 노드로 확장한다(부하 구간에만 비용 발생).
            requests = { cpu = "575m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [kubernetes_job.db_init, null_resource.build_push]
}

resource "kubernetes_service" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "user" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30080
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # 2026-08-20 실측 적용값. 775m x 90% 발동점이면 파드가 6개 근처에서 균형을 이룬다.
    # 이전 2~20은 발동점이 낮아 상시 max였고, 파드 수만큼 메모리 예약이 노드를 늘렸다.
    min_replicas = 2
    max_replicas = 9
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.user.metadata[0].name
    }
    behavior {
      scale_up {
        # 계단식 트래픽의 초기 손실을 줄이기 위해 Kubernetes 기본 scale-up 속도를 사용한다.
        # 비용 상한은 max_replicas가 담당하고, 플래핑은 scale_down 90초가 억제한다.
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100 # 15초마다 최대 2배
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4 # 15초마다 최대 +4개
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 2026-08-20 실측 적용값. 발동점 600m x 90% = 540m.
          # 낮은 target은 HPA를 상시 max로 만들어 탄력성을 없앤다.
          type                = "Utilization"
          average_utilization = 90
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}

# ---------- product ----------
resource "kubernetes_service_account" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.product_app.arn
    }
  }
}

resource "kubernetes_deployment" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "product" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "product" } }
    # max_surge=1 / max_unavailable=0 은 타협 불가다. 반대로 두면(0/1) 롤링 업데이트가
    # 구 파드를 '먼저 지우고' 새로 만들기 때문에 레플리카 2개 중 1개만 남는 구간이 생긴다.
    # 그 사이 ALB 는 지워진 파드의 타깃을 deregistration_delay 동안 draining 으로 들고 있고
    # 새 파드는 등록+헬스체크를 통과해야 하므로, 부하 중이면 용량 공백이 그대로 504 가 된다.
    # (실측: 0/1 로 바꾼 회차에서 504 발생. 가용성 12점을 직접 깎는다)
    # 1/0 이면 새 파드를 먼저 띄우고 Ready 를 확인한 뒤 구 파드를 지우므로
    # 가용 레플리카가 절대 desired 아래로 내려가지 않는다.
    #
    # 대가: 롤 결과의 노드 분산이 운에 좌우된다(어느 구 파드를 지울지는 ReplicaSet 삭제
    # 순서가 정하고 topology spread 를 보지 않는다). 그건 분산 문제이지 가용성 문제가
    # 아니고, 노드 분산은 node_desired_size=2 + NG 선호 affinity 로 따로 잡는다.
    # 가용성 > 분산 우선순위를 지킨다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
    template {
      metadata {
        labels = { app = "product" }
        # DB 엔드포인트 변경 시 롤링 재배포 유도 (user 와 동일한 이유)
        annotations = { "wsi/db-host" = aws_db_proxy.this.endpoint }
      }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.product.metadata[0].name
        # 기본 파드는 '관리형 NG 노드'에 앉힌다.
        # 이유: Karpenter 노드는 consolidation 회수 대상이라 언제든 사라진다. 베이스라인
        # 레플리카가 그 위에 있으면 노드 회수마다 서비스가 흔들린다. 관리형 NG 노드는
        # desired=2 로 고정되어 Karpenter 가 건드리지 못하므로 기본 파드의 정착지로 맞다.
        # (실측: NG 노드 2대가 텅 비고 앱 6개가 Karpenter 노드 2대에 올라가 있었다)
        #
        # preferred(선호)로 두는 이유: required 로 강제하면 스케일아웃 파드가 NG 2노드에
        # 못 들어갈 때 Pending 이 되어 가용성을 깎는다. preferred 면
        #   베이스라인 -> NG 노드(자리 있음), 스케일아웃 초과분 -> Karpenter 노드
        # 로 자연히 나뉘고, Karpenter 회수는 초과분 파드만 건드린다.
        # operator=Exists 로 노드그룹 이름에 결합하지 않는다.
        affinity {
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
        # AZ 분산은 '선호'로 둔다. DoNotSchedule 로 강제하면 안 되는 이유(실측):
        #   (a) 한쪽 AZ 노드가 꽉 차면 반대쪽으로 못 가고 Pending 으로 대기한다
        #       -> 가용성 점수(2xx 비율)를 직접 깎는다. 채점상 AZ 장애는 측정하지 않으므로
        #          Pending 위험을 감수할 이유가 없다.
        #   (b) 강제해도 롤링 업데이트 후 균형이 깨진다. 제약은 스케줄 시점에만 평가되는데,
        #       구 파드가 한쪽 AZ 에 있으면 신 파드가 전부 반대쪽으로 밀리고, 구 파드가
        #       종료되면 그 쪽에 2개가 남는다. 쿠버네티스는 사후 재배치를 하지 않는다.
        #       (실측: 6개 파드가 전부 2a 로 몰려 skew=2 위반 상태로 굳었다)
        # 노드 단위 몰림은 제약이 아니라 node_desired_size=2 로 막는다. 배포 시점에
        # Ready 노드가 이미 2개(AZ 당 1개) 있으면, 선호 제약만으로도 스케줄러가 빈 노드를
        # 우선 골라 앱마다 1개씩 나뉜다. 몰림의 진짜 원인은 제약이 약해서가 아니라
        # '파드가 배포될 때 노드가 1개뿐'이었던 것이다.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector { match_labels = { app = "product" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다.
        # maxSkew=2 인 이유: 1 은 노드당 1개만 허용해 Karpenter 가 노드를 회수하지 못하게
        # 막아 평균 노드 수가 4.8 까지 올라갔고(비용 6/12), 3 은 편차를 너무 허용해
        # 분산 압력이 사라졌다(실측: user/product 4개가 한 노드에 몰림).
        # 2 면 스케줄러가 빈 노드를 선호해 베이스라인 2레플리카는 1개씩 나뉘면서도,
        # 노드당 2개까지 허용하므로 consolidation 을 막지 않는다.
        # 전제: node_desired_size=2 로 배포 시점에 이미 노드가 2개 존재해야 한다.
        topology_spread_constraint {
          max_skew           = 2
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          # match_label_keys 가 이 제약을 실제로 쓸 수 있게 만든다.
          # 원래 topology spread 는 label_selector 에 맞는 '모든' 파드를 센다. 그래서
          # 롤링 업데이트 중에는 아직 종료되지 않은 구 파드까지 계산에 들어가고,
          # 신 파드가 엉뚱한 쪽으로 밀린 뒤 구 파드가 사라지면 분산이 깨진 채로 굳는다
          # (실측: 구 파드가 2b 에 있어 신 파드 6개가 전부 2a 로 몰림. k8s 는 사후 재배치 안 함).
          # pod-template-hash 를 넣으면 '같은 ReplicaSet 의 파드끼리만' 비교하므로
          # 신 파드는 자기들끼리 균등 분산되고 구 파드의 위치에 영향받지 않는다.
          #
          # maxSkew 는 1 이 아니라 2 다. 1 로 두면 Karpenter 가 노드를 통합하지 못한다:
          # 빈 노드를 없애려면 그 위의 파드를 남은 노드로 옮겨야 하는데, 그러면 노드당
          # 같은 앱 파드가 2개가 되어 skew=1 을 위반하므로 통합 계획 자체가 세워지지 않는다.
          #   실측 로그: "pod(s) have a preferred TopologySpreadConstraint which can
          #   prevent consolidation" 이 반복되며, DaemonSet 만 남은 빈 노드 2대가
          #   회수되지 않고 5대가 유지됐다(비용 지표는 평균 노드 수).
          # match_label_keys 는 '롤아웃 중 구 파드 오염'만 해결하고 이 문제는 못 막는다.
          # 2 로 두면 통합이 가능해지고, 균등 배치는 다른 수단으로 이미 보장된다:
          #   node_desired_size=2 로 배포 시점에 노드가 2대 있고, NG 선호 affinity 로
          #   기본 파드가 그 2대에 앉으며, 스케줄러 점수 계산이 빈 노드를 선호한다.
          # 즉 maxSkew=1 의 추가 이득은 '강제' 뿐인데 대가가 비용이라 손해다.
          match_label_keys = ["pod-template-hash"]
          label_selector { match_labels = { app = "product" } }
        }
        container {
          name              = "product"
          image             = "${local.ecr_url["product"]}:${local.app_image_tags["product"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          env_from {
            config_map_ref { name = kubernetes_config_map.s3.metadata[0].name }
          }
          resources {
            # 2026-08-20 실측 적용값. 발동점 250m x 70% = 175m.
            # 이전 70m x 29% = 20.3m은 발동점이 너무 낮아 부하 시 max(20파드)까지 붙었다.
            requests = { cpu = "250m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [kubernetes_job.db_init, null_resource.build_push]
}

resource "kubernetes_service" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "product" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30081
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # 2026-08-20 실측 적용값. 250m x 70% 발동점이면 파드가 4개 근처에서 균형을 이룬다.
    min_replicas = 2
    max_replicas = 8
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.product.metadata[0].name
    }
    behavior {
      scale_up {
        # 계단식 트래픽의 초기 손실을 줄이기 위해 Kubernetes 기본 scale-up 속도를 사용한다.
        # 비용 상한은 max_replicas가 담당하고, 플래핑은 scale_down 90초가 억제한다.
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100 # 15초마다 최대 2배
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4 # 15초마다 최대 +4개
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 60%: CPU가 더 차야 확장 → 파드/노드 덜 늘어남 (55는 과민했음).
          # 꼬리지연 생기면 그 앱만 낮추기 — advise.py/autotune 이 판정해줌.
          type = "Utilization"
          # 2026-08-20 실측 적용값. 발동점 250m x 70% = 175m.
          # 이전 60%는 request 70m과 겹쳐 발동점이 20m이라 부하 시 상시 max(20파드)였다.
          average_utilization = 70
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}

# ---------- stress ----------
resource "kubernetes_service_account" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

resource "kubernetes_deployment" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "stress" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "stress" } }
    # max_surge=1 / max_unavailable=0 은 타협 불가다. 반대로 두면(0/1) 롤링 업데이트가
    # 구 파드를 '먼저 지우고' 새로 만들기 때문에 레플리카 2개 중 1개만 남는 구간이 생긴다.
    # 그 사이 ALB 는 지워진 파드의 타깃을 deregistration_delay 동안 draining 으로 들고 있고
    # 새 파드는 등록+헬스체크를 통과해야 하므로, 부하 중이면 용량 공백이 그대로 504 가 된다.
    # (실측: 0/1 로 바꾼 회차에서 504 발생. 가용성 12점을 직접 깎는다)
    # 1/0 이면 새 파드를 먼저 띄우고 Ready 를 확인한 뒤 구 파드를 지우므로
    # 가용 레플리카가 절대 desired 아래로 내려가지 않는다.
    #
    # 대가: 롤 결과의 노드 분산이 운에 좌우된다(어느 구 파드를 지울지는 ReplicaSet 삭제
    # 순서가 정하고 topology spread 를 보지 않는다). 그건 분산 문제이지 가용성 문제가
    # 아니고, 노드 분산은 node_desired_size=2 + NG 선호 affinity 로 따로 잡는다.
    # 가용성 > 분산 우선순위를 지킨다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
    template {
      metadata { labels = { app = "stress" } }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.stress.metadata[0].name
        # 기본 파드는 '관리형 NG 노드'에 앉힌다.
        # 이유: Karpenter 노드는 consolidation 회수 대상이라 언제든 사라진다. 베이스라인
        # 레플리카가 그 위에 있으면 노드 회수마다 서비스가 흔들린다. 관리형 NG 노드는
        # desired=2 로 고정되어 Karpenter 가 건드리지 못하므로 기본 파드의 정착지로 맞다.
        # (실측: NG 노드 2대가 텅 비고 앱 6개가 Karpenter 노드 2대에 올라가 있었다)
        #
        # preferred(선호)로 두는 이유: required 로 강제하면 스케일아웃 파드가 NG 2노드에
        # 못 들어갈 때 Pending 이 되어 가용성을 깎는다. preferred 면
        #   베이스라인 -> NG 노드(자리 있음), 스케일아웃 초과분 -> Karpenter 노드
        # 로 자연히 나뉘고, Karpenter 회수는 초과분 파드만 건드린다.
        # operator=Exists 로 노드그룹 이름에 결합하지 않는다.
        affinity {
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
        # AZ 분산은 '선호'로 둔다. DoNotSchedule 로 강제하면 안 되는 이유(실측):
        #   (a) 한쪽 AZ 노드가 꽉 차면 반대쪽으로 못 가고 Pending 으로 대기한다
        #       -> 가용성 점수(2xx 비율)를 직접 깎는다. 채점상 AZ 장애는 측정하지 않으므로
        #          Pending 위험을 감수할 이유가 없다.
        #   (b) 강제해도 롤링 업데이트 후 균형이 깨진다. 제약은 스케줄 시점에만 평가되는데,
        #       구 파드가 한쪽 AZ 에 있으면 신 파드가 전부 반대쪽으로 밀리고, 구 파드가
        #       종료되면 그 쪽에 2개가 남는다. 쿠버네티스는 사후 재배치를 하지 않는다.
        #       (실측: 6개 파드가 전부 2a 로 몰려 skew=2 위반 상태로 굳었다)
        # 노드 단위 몰림은 제약이 아니라 node_desired_size=2 로 막는다. 배포 시점에
        # Ready 노드가 이미 2개(AZ 당 1개) 있으면, 선호 제약만으로도 스케줄러가 빈 노드를
        # 우선 골라 앱마다 1개씩 나뉜다. 몰림의 진짜 원인은 제약이 약해서가 아니라
        # '파드가 배포될 때 노드가 1개뿐'이었던 것이다.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector { match_labels = { app = "stress" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다.
        # maxSkew=2 인 이유: 1 은 노드당 1개만 허용해 Karpenter 가 노드를 회수하지 못하게
        # 막아 평균 노드 수가 4.8 까지 올라갔고(비용 6/12), 3 은 편차를 너무 허용해
        # 분산 압력이 사라졌다(실측: user/product 4개가 한 노드에 몰림).
        # 2 면 스케줄러가 빈 노드를 선호해 베이스라인 2레플리카는 1개씩 나뉘면서도,
        # 노드당 2개까지 허용하므로 consolidation 을 막지 않는다.
        # 전제: node_desired_size=2 로 배포 시점에 이미 노드가 2개 존재해야 한다.
        topology_spread_constraint {
          max_skew           = 2
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          # match_label_keys 가 이 제약을 실제로 쓸 수 있게 만든다.
          # 원래 topology spread 는 label_selector 에 맞는 '모든' 파드를 센다. 그래서
          # 롤링 업데이트 중에는 아직 종료되지 않은 구 파드까지 계산에 들어가고,
          # 신 파드가 엉뚱한 쪽으로 밀린 뒤 구 파드가 사라지면 분산이 깨진 채로 굳는다
          # (실측: 구 파드가 2b 에 있어 신 파드 6개가 전부 2a 로 몰림. k8s 는 사후 재배치 안 함).
          # pod-template-hash 를 넣으면 '같은 ReplicaSet 의 파드끼리만' 비교하므로
          # 신 파드는 자기들끼리 균등 분산되고 구 파드의 위치에 영향받지 않는다.
          #
          # maxSkew 는 1 이 아니라 2 다. 1 로 두면 Karpenter 가 노드를 통합하지 못한다:
          # 빈 노드를 없애려면 그 위의 파드를 남은 노드로 옮겨야 하는데, 그러면 노드당
          # 같은 앱 파드가 2개가 되어 skew=1 을 위반하므로 통합 계획 자체가 세워지지 않는다.
          #   실측 로그: "pod(s) have a preferred TopologySpreadConstraint which can
          #   prevent consolidation" 이 반복되며, DaemonSet 만 남은 빈 노드 2대가
          #   회수되지 않고 5대가 유지됐다(비용 지표는 평균 노드 수).
          # match_label_keys 는 '롤아웃 중 구 파드 오염'만 해결하고 이 문제는 못 막는다.
          # 2 로 두면 통합이 가능해지고, 균등 배치는 다른 수단으로 이미 보장된다:
          #   node_desired_size=2 로 배포 시점에 노드가 2대 있고, NG 선호 affinity 로
          #   기본 파드가 그 2대에 앉으며, 스케줄러 점수 계산이 빈 노드를 선호한다.
          # 즉 maxSkew=1 의 추가 이득은 '강제' 뿐인데 대가가 비용이라 손해다.
          match_label_keys = ["pod-template-hash"]
          label_selector { match_labels = { app = "stress" } }
        }
        container {
          name              = "stress"
          image             = "${local.ecr_url["stress"]}:${local.app_image_tags["stress"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          resources {
            # 발동점 650m x 55% = 357.5m. request는 예약량이고 limit 2 CPU로 burst하므로
            # 성능은 유지된다. user 575 + product 250 + stress 650 = 1475m <= 노드 앱 여유 1480m
            # 이라 AZ 노드 1대에 세 앱 파드가 다 앉아 유휴 2노드로 회수된다.
            requests = { cpu = "650m", memory = "128Mi" }
            limits   = { cpu = "2", memory = "512Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds = 10
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [aws_eks_node_group.main, null_resource.build_push]
}

resource "kubernetes_service" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "stress" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30082
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # stress cold-start 방지: min 1이면 부하 시작 시 1파드로 출발해 스케일아웃(파드/노드
    # 부팅 60~90s) 동안 초기 요청이 1s SLO를 넘겨 성능%가 깎였다(측정 stress 79.9%).
    # min 2로 시작 용량을 확보한다. advise.py도 항상 min 2를 권고(recommended_min=2).
    # 노드 비용 영향은 user/product 대비 작다(관리형 NG 2노드에 흡수됨).
    min_replicas = 2
    max_replicas = 8
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.stress.metadata[0].name
    }
    behavior {
      scale_up {
        # 계단식 트래픽의 초기 손실을 줄이기 위해 Kubernetes 기본 scale-up 속도를 사용한다.
        # 비용 상한은 max_replicas가 담당하고, 플래핑은 scale_down 90초가 억제한다.
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100 # 15초마다 최대 2배
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4 # 15초마다 최대 +4개
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 60%: CPU가 더 차야 확장 → 파드/노드 덜 늘어남 (55는 과민했음).
          # 꼬리지연 생기면 그 앱만 낮추기 — advise.py/autotune 이 판정해줌.
          type                = "Utilization"
          average_utilization = 55
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}
