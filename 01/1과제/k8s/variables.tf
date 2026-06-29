variable "region" {
  type    = string
  default = "ap-northeast-2"
}
variable "cluster_name" {
  type    = string
  default = "wsc-eks-cluster"
}
variable "table_name" {
  type    = string
  default = "wsc-dynamo"
}
variable "vpc_name" {
  type    = string
  default = "wsc-vpc"
}
variable "ecr_repo" {
  type    = string
  default = "book-ecr"
}
variable "tg_name" {
  type    = string
  default = "wsc-book-tg"
}
