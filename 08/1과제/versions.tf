terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# 기본 리전 provider (모든 리소스는 ap-northeast-2)
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "skillskorea-2026-task1"
      Player  = var.player_id
    }
  }
}

# CloudFront 관련 일부 글로벌 리소스용 us-east-1 provider (필요 시 사용)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
