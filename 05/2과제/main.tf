###############################################
# 05 2과제 루트 - 4개 모듈 한 번에 apply
# terraform apply -var pin=<비번호> -var alarm_email=<이메일>
###############################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ─── 리전별 AWS Provider ───
provider "aws" {
  alias  = "useast1" # Module 1 CDN (Lambda@Edge 필수)
  region = "us-east-1"
}

provider "aws" {
  alias  = "apsoutheast1" # Module 2 Real-time data analytics
  region = "ap-southeast-1"
}

provider "aws" {
  alias  = "apnortheast2" # Module 3 Cloud event handling
  region = "ap-northeast-2"
}

provider "aws" {
  alias  = "eucentral1" # Module 4 Keycloak
  region = "eu-central-1"
}

# ─── 변수 ───
variable "pin" {
  description = "비번호 - CDN S3 버킷 이름 gj2026-cdn-bucket-<pin>"
  type        = string
}

variable "alarm_email" {
  description = "Module 3 SNS 이메일 알림 수신 주소 (채점항목 3-8). 미입력 시 구독 생략"
  type        = string
  default     = ""
}

variable "keycloak_admin_password" {
  description = "Module 4 Keycloak admin 패스워드"
  type        = string
  default     = "admin1234!"
}

variable "cdn_public_url" {
  description = "CDN Lambda Function URL: true=공개(NONE, 대회 기본), false=AWS_IAM+OAC(공개 차단 계정 우회)"
  type        = bool
  default     = true
}

# ─── Module 1: CDN (us-east-1) ───
module "cdn" {
  source         = "./module1/infra"
  pin            = var.pin
  cdn_public_url = var.cdn_public_url
  providers = {
    aws     = aws.useast1
    archive = archive
    null    = null
  }
}

# ─── Module 2: Real-time data analytics (ap-southeast-1) ───
module "data" {
  source = "./module2"
  providers = {
    aws  = aws.apsoutheast1
    null = null
  }
}

# ─── Module 3: Cloud event handling (ap-northeast-2) ───
module "event" {
  source      = "./module3/infra"
  alarm_email = var.alarm_email
  providers = {
    aws     = aws.apnortheast2
    archive = archive
  }
}

# ─── Module 4: Keycloak (eu-central-1) ───
module "keycloak" {
  source                  = "./module4"
  keycloak_admin_password = var.keycloak_admin_password
  providers = {
    aws  = aws.eucentral1
    tls  = tls
    null = null
  }
}

# ─── 출력 ───
output "cdn_cloudfront_domain" {
  value = module.cdn.cloudfront_domain
}

output "cdn_s3_bucket" {
  value = module.cdn.s3_bucket_name
}

output "data_kafka_ec2_ip" {
  value = module.data.kafka_ec2_public_ip
}

output "data_nlb_dns" {
  value = module.data.nlb_dns
}

output "event_ec2_ip" {
  value = module.event.ec2_public_ip
}

output "keycloak_ip" {
  value = module.keycloak.keycloak_public_ip
}

output "keycloak_url" {
  value = module.keycloak.keycloak_https_url
}
