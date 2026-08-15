# 단일 aws provider. region 은 변수로만 제어하므로 다른 계정/리전에서
# 그대로 재사용 가능하다. CloudFront 는 글로벌 서비스라 이 provider 로 생성해도
# 무방하며, 기본 인증서(*.cloudfront.net)를 쓰므로 us-east-1 ACM 별도 provider 불필요.
provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Task      = "system-operation-demo"
    }
  }
}
