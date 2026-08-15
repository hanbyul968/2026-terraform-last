# ---------------------------------------------------------------------------
# 이식성: 아래 값만 바꾸면 다른 계정/리전/날짜에서도 그대로 apply 된다.
# 계정 ID, ARN, AMI, AZ 이름 등은 어디에도 하드코딩하지 않는다(전부 data source).
# ---------------------------------------------------------------------------

variable "region" {
  type        = string
  default     = "ap-northeast-2"
  description = "리소스를 생성할 리전. 문제지 기본값 ap-northeast-2."
}

variable "aws_profile" {
  type        = string
  default     = ""
  description = "AWS named profile. 비우면 기본 자격증명 체인(환경변수/기본 프로필) 사용."
}

variable "project" {
  type        = string
  default     = "wsc-sysops-demo"
  description = "리소스 이름/태그 prefix. 다른 환경과 충돌 방지를 위해 임의 suffix 가 자동으로 붙는다."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.30.0.0/16"
  description = "VPC CIDR. 기존 VPC 와 겹치지 않는 대역."
}

variable "az_count" {
  type        = number
  default     = 2
  description = "사용할 가용영역 수(고가용성). 데이터소스로 리전의 AZ 를 자동 선택하므로 리전 이동에 안전."
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count 는 2 또는 3 이어야 합니다(고가용성 최소 2)."
  }
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 인스턴스 타입. 문제지 요구: t3.micro 전용."
}

variable "asg_min_size" {
  type        = number
  default     = 2
  description = "ASG 최소 대수. 2AZ 고가용성을 위해 최소 2."
}

variable "asg_desired_size" {
  type        = number
  default     = 2
  description = "ASG 희망 대수(시작값). 트래픽 주입 전에는 최소로 유지."
}

variable "asg_max_size" {
  type        = number
  default     = 4
  description = "ASG 최대 대수. 트래픽 급증 시 스케일 아웃 상한."
}

variable "cpu_target" {
  type        = number
  default     = 50
  description = "타깃 트래킹 스케일링의 평균 CPU 목표(%). 낮을수록 응답시간 유리/비용 증가."
}

variable "container_port" {
  type        = number
  default     = 8080
  description = "color 앱 리슨 포트. 문제지: TCP/8080."
}

variable "color_path" {
  type        = string
  default     = "/v1/color"
  description = "color API 경로(문서화/스모크테스트용)."
}

variable "healthcheck_path" {
  type        = string
  default     = "/healthcheck"
  description = "헬스체크 경로. ALB Target Group 헬스체크에 사용."
}

variable "log_retention_days" {
  type        = number
  default     = 14
  description = "CloudWatch 로그 보존일(비용 최적화)."
}

variable "cloudfront_price_class" {
  type        = string
  default     = "PriceClass_200"
  description = "CloudFront 가격 등급. 200 은 아시아(서울) 포함, 저비용."
  validation {
    condition     = contains(["PriceClass_All", "PriceClass_200", "PriceClass_100"], var.cloudfront_price_class)
    error_message = "PriceClass_All | PriceClass_200 | PriceClass_100 중 하나여야 합니다."
  }
}
