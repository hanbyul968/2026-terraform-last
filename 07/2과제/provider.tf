terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# 모듈1: 서울
provider "aws" {
  alias  = "seoul"
  region = "ap-northeast-2"
}

# 모듈2: 도쿄
provider "aws" {
  alias  = "tokyo"
  region = "ap-northeast-1"
}

# 모듈3: 싱가포르
provider "aws" {
  alias  = "singapore"
  region = "ap-southeast-1"
}

# 모듈4: 오레곤
provider "aws" {
  alias  = "oregon"
  region = "us-west-2"
}

provider "aws" {
  region = "ap-northeast-2"
}
