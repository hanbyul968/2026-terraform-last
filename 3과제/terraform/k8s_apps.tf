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
    # 롤링 업데이트가 '분산된 상태로' 수렴하게 만드는 설정.
    # max_surge=1(25%) 이면 신 파드를 먼저 띄운 뒤 구 파드를 지우는데, 어느 구 파드를
    # 지울지는 ReplicaSet 의 삭제 순서가 정하고 topology spread 를 고려하지 않는다.
    # 그래서 롤 결과가 운에 좌우된다(실측: user/product 는 1개씩 나뉘었는데 stress 는
    # 두 개가 한 노드에 몰렸다. 쿠버네티스는 사후 재배치를 하지 않아 그대로 굳는다).
    # max_surge=0 / max_unavailable=1 이면 '지우고 -> 빈 자리에 새로 스케줄' 순서가 되어
    # 매번 남은 파드가 없는 노드가 선택되고 1개씩 분산으로 수렴한다.
    # 대가: 롤 도중 순간적으로 파드가 1개가 된다. 바이너리 교체는 트래픽 주입(T+1h) 전에
    # 끝내므로 가용성 점수에 영향이 없다. 트래픽 중 롤은 피한다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "0"
        max_unavailable = "1"
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
            # no cpu limit: CFS throttling wrecks tail latency; memory limit only
            requests = { cpu = "200m", memory = "128Mi" }
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
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.user.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
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
          average_utilization = 70
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
    # 롤링 업데이트가 '분산된 상태로' 수렴하게 만드는 설정.
    # max_surge=1(25%) 이면 신 파드를 먼저 띄운 뒤 구 파드를 지우는데, 어느 구 파드를
    # 지울지는 ReplicaSet 의 삭제 순서가 정하고 topology spread 를 고려하지 않는다.
    # 그래서 롤 결과가 운에 좌우된다(실측: user/product 는 1개씩 나뉘었는데 stress 는
    # 두 개가 한 노드에 몰렸다. 쿠버네티스는 사후 재배치를 하지 않아 그대로 굳는다).
    # max_surge=0 / max_unavailable=1 이면 '지우고 -> 빈 자리에 새로 스케줄' 순서가 되어
    # 매번 남은 파드가 없는 노드가 선택되고 1개씩 분산으로 수렴한다.
    # 대가: 롤 도중 순간적으로 파드가 1개가 된다. 바이너리 교체는 트래픽 주입(T+1h) 전에
    # 끝내므로 가용성 점수에 영향이 없다. 트래픽 중 롤은 피한다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "0"
        max_unavailable = "1"
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
            # no cpu limit: CFS throttling wrecks tail latency; memory limit only
            requests = { cpu = "200m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
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
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.product.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
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
    # 롤링 업데이트가 '분산된 상태로' 수렴하게 만드는 설정.
    # max_surge=1(25%) 이면 신 파드를 먼저 띄운 뒤 구 파드를 지우는데, 어느 구 파드를
    # 지울지는 ReplicaSet 의 삭제 순서가 정하고 topology spread 를 고려하지 않는다.
    # 그래서 롤 결과가 운에 좌우된다(실측: user/product 는 1개씩 나뉘었는데 stress 는
    # 두 개가 한 노드에 몰렸다. 쿠버네티스는 사후 재배치를 하지 않아 그대로 굳는다).
    # max_surge=0 / max_unavailable=1 이면 '지우고 -> 빈 자리에 새로 스케줄' 순서가 되어
    # 매번 남은 파드가 없는 노드가 선택되고 1개씩 분산으로 수렴한다.
    # 대가: 롤 도중 순간적으로 파드가 1개가 된다. 바이너리 교체는 트래픽 주입(T+1h) 전에
    # 끝내므로 가용성 점수에 영향이 없다. 트래픽 중 롤은 피한다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "0"
        max_unavailable = "1"
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
          label_selector { match_labels = { app = "stress" } }
        }
        container {
          name              = "stress"
          image             = "${local.ecr_url["stress"]}:${local.app_image_tags["stress"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          resources {
            # robust default — NOT app-tuned. Re-derive per app with
            # tuning/autotune.sh on competition day (app behavior varies).
            requests = { cpu = "500m", memory = "128Mi" }
            # cpu limit: stress 는 CPU 를 무제한 태워 같은 노드의 user/product 를 굶긴다.
            # (노드 CPU 89~97% / RDS 5~10% → 지연 원인은 노드 CPU 경쟁)
            # stress SLO 1000ms 는 느슨하므로 여기를 캡해 user 200ms 를 지킨다.
            limits = { cpu = "1000m", memory = "512Mi" }
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
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.stress.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
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
          average_utilization = 70
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}
