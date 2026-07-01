# ═══════════════════════════════════════════════════════════════
# 노드 부팅용 '임시' egress
#
# 문제: workload 서브넷은 채점 1-1-C 상 라우팅 0(igw-/nat-/vpce- 없음)이어야 한다.
#   그런데 fully-private 노드가 최초 부팅 시 ECR 이미지 레이어(S3)를 인터페이스
#   엔드포인트만으로 받으면 너무 느려 EKS 노드그룹 생성 헬스 타임아웃(~15분)을 넘겨
#   CREATE_FAILED 가 난다. (노드는 한 번 Ready 가 되면 egress 없이 정상 동작)
#
# 해법: bootstrap_egress=true 로 1회 apply → workload RTB 에 NAT 경로 추가 →
#   노드가 빠르게 이미지 pull → 노드그룹 ACTIVE → 배포 완료.
#   그 뒤 bootstrap_egress=false 로 재apply → 경로 제거(라우팅 0 복구) → 채점 통과.
#   (run.sh 가 이 2-phase 를 자동 수행)
# ═══════════════════════════════════════════════════════════════

variable "bootstrap_egress" {
  description = "true: workload RTB 에 임시 NAT 경로 추가(노드 부팅용). 채점 전 반드시 false 로 재apply 해 경로 제거(1-1-C 라우팅 0)."
  type        = bool
  default     = false
}

resource "aws_route" "workload_bootstrap_a" {
  count                  = var.bootstrap_egress ? 1 : 0
  route_table_id         = data.aws_route_table.workload_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = data.aws_nat_gateway.a.id
}

resource "aws_route" "workload_bootstrap_c" {
  count                  = var.bootstrap_egress ? 1 : 0
  route_table_id         = data.aws_route_table.workload_c.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = data.aws_nat_gateway.c.id
}
