variable "player_id" {
  description = "선수ID (모든 리소스 이름 접두어). apply 시 입력. 소문자/숫자/하이픈만, 예) hong"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.player_id))
    error_message = "player_id는 소문자/숫자/하이픈만 사용하고 소문자 또는 숫자로 시작해야 합니다 (S3 버킷명 규칙)."
  }
}

variable "region" {
  description = "AWS 리전 (문제 요구: ap-northeast-2 서울)"
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "Public Subnet을 배치할 가용영역 2개"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "vpc_cidr" {
  description = "VPC CIDR (문제 고정값)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR 2개"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "container_port" {
  description = "컨테이너 포트 (문제 고정: 8080)"
  type        = number
  default     = 8080
}

variable "task_cpu" {
  description = "ECS Task CPU Units (문제 고정: 256)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "ECS Task Memory MiB (문제 고정: 512)"
  type        = string
  default     = "512"
}

variable "log_group_name" {
  description = "CloudWatch Logs 로그 그룹 이름 (문제 고정값)"
  type        = string
  default     = "/skillskorea/ecs/app"
}
