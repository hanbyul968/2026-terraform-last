# ---------------------------------------------------------------------------
# 인스턴스 타입에서 파생되는 모든 사이징 값 (단일 소스)
#
# 목적: 대회날 "EC2 인스턴스 타입만 사용" 스펙이 t3.medium 이 아닌 다른 타입으로
# 바뀌어도 var.node_instance_type 한 곳만 고치면 아래가 전부 자동으로 따라간다.
#   - 파드 CPU/메모리 request (노드 용량 비율로 지정 가능)
#   - kubelet maxPods (Prefix Delegation 실제 상한을 넘지 않게 계산)
#   - Karpenter 총 vCPU 상한 (원하는 최대 노드 수 x 타입 vCPU)
#
# 하드코딩하면 안 되는 이유(실측): 파드 request 를 t3.medium(2 vCPU) 기준 절대값으로
# 박아두면, 더 큰 타입으로 바꿨을 때 노드당 파드가 몇 개 들어가는지가 달라져
# bin-packing 이 어긋나고 비용 ratio 예측이 전부 틀어진다.
# ---------------------------------------------------------------------------

data "aws_ec2_instance_type" "node" {
  instance_type = var.node_instance_type
}

# Karpenter 가 여러 타입을 고를 수 있게 해도, 사이징 계산은 "가장 작은 타입" 기준으로
# 해야 안전하다(작은 노드에 안 들어가면 Pending 이 된다). 지금은 기본이 단일 타입.
data "aws_ec2_instance_type" "karpenter" {
  for_each      = toset(local.karpenter_instance_types)
  instance_type = each.key
}

locals {
  # ---------- 아키텍처 (인스턴스 타입에서 파생) ----------
  # 하드코딩하면 안 되는 이유: 타입이 Graviton(t4g/m7g/c7g...)으로 바뀌면
  # ami_type(x86_64 고정)과 docker --platform(amd64 고정)이 조용히 어긋나
  # 노드가 안 뜨거나 이미지가 실행되지 않는다.
  node_arch = contains(data.aws_ec2_instance_type.node.supported_architectures, "x86_64") ? "x86_64" : "arm64"

  ng_ami_type     = local.node_arch == "x86_64" ? "AL2023_x86_64_STANDARD" : "AL2023_ARM_64_STANDARD"
  docker_platform = local.node_arch == "x86_64" ? "linux/amd64" : "linux/arm64"
  # Karpenter NodePool 이 다른 아키텍처를 고르지 못하게 요구조건으로 넣는다.
  karpenter_arch = local.node_arch

  # ---------- 노드 물리 용량 ----------
  node_vcpu    = data.aws_ec2_instance_type.node.default_vcpus
  node_cpu_m   = local.node_vcpu * 1000
  node_mem_mib = data.aws_ec2_instance_type.node.memory_size # MiB

  # Karpenter 가 고를 수 있는 타입 중 가장 작은 vCPU (사이징 하한 기준)
  karpenter_min_vcpu = min([
    for t in data.aws_ec2_instance_type.karpenter : t.default_vcpus
  ]...)

  # ---------- 시스템 예약 (kubelet + DaemonSet + kube-reserved) ----------
  # EKS 는 노드 크기에 따라 예약량이 달라진다. 정확한 공식 대신 보수적인 근사를 쓴다:
  #   - CPU: 첫 1 vCPU 의 6% + 나머지의 1% + DaemonSet(aws-node/kube-proxy) 여유
  #   - 실측(t3.medium): allocatable 1930m, DaemonSet 포함 앱 가용 약 1450~1730m
  # var.system_reserved_cpu_m 로 직접 덮어쓸 수 있다.
  system_reserved_cpu_m = var.system_reserved_cpu_m >= 0 ? var.system_reserved_cpu_m : (
    ceil(70 + (local.node_cpu_m - 1000) * 0.01) + 250
  )

  # 앱 파드가 실제로 쓸 수 있는 노드당 CPU (m)
  node_app_cpu_m = max(local.node_cpu_m - local.system_reserved_cpu_m, 100)

  # ---------- Prefix Delegation 기준 실제 Pod 상한 ----------
  # ENI 당 (IP 수 - 1) 개의 /28 prefix, prefix 당 16 IP. +2 는 hostNetwork 파드 여유.
  # 이 값을 넘겨 maxPods 를 올리면 IP 고갈로 파드가 ContainerCreating 에서 멈춘다.
  eni_count       = data.aws_ec2_instance_type.node.maximum_network_interfaces
  ips_per_eni     = data.aws_ec2_instance_type.node.maximum_ipv4_addresses_per_interface
  prefix_max_pods = local.eni_count * (local.ips_per_eni - 1) * 16 + 2

  # 요청값 / EKS 권장 상한(110) / 타입의 물리 상한 중 가장 작은 값
  node_max_pods_effective = min(var.node_max_pods, 110, local.prefix_max_pods)

  # ---------- Karpenter 총 vCPU 상한 ----------
  # 앱 맵에서 자동 계산한다. 앱이 추가/삭제되거나 max_replicas/request 가 바뀌면
  # 상한도 같이 움직이므로, 대회날 앱이 바뀌어도 손댈 필요가 없다.
  #
  # 필요량 = 모든 앱의 (max_replicas x request) 합  ← HPA 가 최대로 늘었을 때의 예약량
  # 그 중 관리형 NG 가 감당하는 몫을 빼고, 나머지를 Karpenter 가 채운다. +1 은 여유.
  #
  # 상한이 낮으면 부하 시 파드가 Pending 으로 남아 순손실이 된다(실측: 상한 6 vCPU 에서
  # 파드 2개가 4분 넘게 Pending). 상한은 유휴 노드 수와 무관하다 — 유휴는
  # min_replicas x request 가 결정하므로 상한을 넉넉히 잡아도 비용이 늘지 않는다.
  peak_cpu_request_m = sum(concat([0], [
    for name, a in local.apps : a.cpu_request_m * a.max_replicas
  ]))
  peak_nodes_needed    = ceil(local.peak_cpu_request_m / local.node_app_cpu_m)
  karpenter_nodes_auto = max(local.peak_nodes_needed - var.node_desired_size, 0) + 1

  # 우선순위: karpenter_cpu_limit(직접 vCPU) > karpenter_max_nodes(직접 노드 수) > 자동
  karpenter_cpu_limit_effective = var.karpenter_cpu_limit > 0 ? var.karpenter_cpu_limit : (
    var.karpenter_max_nodes > 0 ? var.karpenter_max_nodes * local.karpenter_min_vcpu
    : local.karpenter_nodes_auto * local.karpenter_min_vcpu
  )

  # 격리 노드풀의 vCPU 상한. 여기서 비용 vs 폭식앱 성능 트레이드오프를 조절한다.
  # 인스턴스 타입이 바뀌어도 "최대 몇 대" 의도가 유지된다.
  karpenter_isolated_cpu_limit = var.karpenter_isolated_max_nodes * local.karpenter_min_vcpu

  # ---------- 비용 채점 환산 ----------
  # 채점은 "평균 EC2 대수 / 기준 2대" 이므로 노드 수가 곧 비용이다.
  # 격리 앱은 전용 노드풀로 가므로 일반 노드와 따로 계산해야 실제 노드 수가 맞는다.
  baseline_general_cpu_m = sum(concat([0], [
    for name, a in local.apps : a.cpu_request_m * a.min_replicas if !a.isolate
  ]))
  baseline_isolated_cpu_m = sum(concat([0], [
    for name, a in local.apps : a.cpu_request_m * a.min_replicas if a.isolate
  ]))

  baseline_general_nodes  = ceil(local.baseline_general_cpu_m / local.node_app_cpu_m)
  baseline_isolated_nodes = ceil(local.baseline_isolated_cpu_m / local.node_app_cpu_m)

  # 유휴 상태에서 예상되는 총 노드 수 = max(NG 고정대수, 일반 앱 필요대수) + 격리 노드
  # 비용 ratio 는 이 값 / 2 에 수렴한다 (채점 기준 2대).
  baseline_nodes_total = max(var.node_desired_size, local.baseline_general_nodes) + local.baseline_isolated_nodes
  baseline_cost_ratio  = local.baseline_nodes_total / 2
}
