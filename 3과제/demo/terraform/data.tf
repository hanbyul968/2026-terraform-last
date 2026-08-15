# ---------------------------------------------------------------------------
# 전부 data source / 동적 조회 -> 계정 ID, AMI, AZ 이름 하드코딩 없음.
# 다른 계정/리전/날짜에서도 그대로 최신값을 조회해 apply 된다.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# 리전에서 사용 가능한 AZ 를 동적으로 선택(리전 이동에 안전)
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# 최신 Amazon Linux 2023 x86_64 AMI (문제지: AL2023, x86 빌드). 날짜/리전 무관하게 최신 조회.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# CloudFront origin-facing 관리형 prefix list -> ALB 인바운드를 CloudFront 로만 제한.
# (모든 리전에서 조회 가능한 글로벌 prefix list)
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# CloudFront 관리형 정책: 캐시 비활성(랜덤 응답이라 캐싱 금지) + 원본으로 전 요청 전달
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
