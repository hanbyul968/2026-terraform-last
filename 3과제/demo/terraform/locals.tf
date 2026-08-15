# 다른 환경(계정/리전)에서 동시에 써도 이름이 충돌하지 않도록 짧은 임의 suffix.
# state 에 저장되어 apply 마다 안정적으로 유지된다.
resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  name   = "${var.project}-${random_string.suffix.result}"
  suffix = random_string.suffix.result

  # 선택된 AZ (요청 개수만큼)
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 로그/메트릭 식별자
  log_group_name    = "/${var.project}/color"
  metrics_namespace = "${var.project}/color"
}
