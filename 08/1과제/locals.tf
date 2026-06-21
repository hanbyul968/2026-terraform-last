data "aws_caller_identity" "current" {}

locals {
  prefix      = var.player_id
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.player_id}-static-site"
  table_name  = "${var.player_id}-booking-table"
  ecr_repo    = "${var.player_id}-book-ecr"
}
