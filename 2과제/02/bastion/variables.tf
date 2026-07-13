variable "player_id" {
  type    = string
  default = "wsc"
}
variable "region" {
  description = "Bastion 리전 (모듈은 각자 리전 사용). 기본 ap-southeast-1"
  type        = string
  default     = "ap-southeast-1"
}
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
