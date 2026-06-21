############################
# Staging S3 (for EC2 file provisioning)
############################

resource "aws_s3_bucket" "staging" {
  bucket        = "gj2026-setup-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "app_dockerfile" {
  bucket = aws_s3_bucket.staging.id
  key    = "application/Dockerfile"
  source = "${path.module}/application/Dockerfile"
}

resource "aws_s3_object" "app_binary" {
  bucket = aws_s3_bucket.staging.id
  key    = "application/book-linux-amd64_v1.0.1"
  source = "${path.module}/application/book-linux-amd64_v1.0.1"
}

resource "aws_s3_object" "k8s_files" {
  for_each = fileset("${path.module}/k8s", "**")
  bucket   = aws_s3_bucket.staging.id
  key      = "k8s/${each.value}"
  source   = "${path.module}/k8s/${each.value}"
}
