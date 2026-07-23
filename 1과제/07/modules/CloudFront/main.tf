data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# OAC for S3
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# VPC Origin for ALB
resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = "app-origin"
    arn                    = var.alb_arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  # AWS documents that VPC Origin deployment can take up to 15 minutes.
  # Keep a wider provider timeout so a healthy deployment is not cancelled.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

# CloudFront creates this service-managed SG when the first VPC Origin is
# deployed. Add it as an ALB source before deploying the distribution.
data "aws_security_group" "vpc_origin_service" {
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  depends_on = [aws_cloudfront_vpc_origin.alb]
}

resource "aws_security_group_rule" "alb_from_vpc_origin" {
  type                     = "ingress"
  security_group_id        = var.alb_sg_id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = data.aws_security_group.vpc_origin_service.id
  description              = "Allow only the CloudFront VPC Origin service SG"
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "this" {
  comment     = var.distribution_comment
  enabled     = true
  price_class = "PriceClass_All"
  web_acl_id  = aws_wafv2_web_acl.this.arn

  depends_on = [aws_security_group_rule.alb_from_vpc_origin]

  origin {
    domain_name              = "${var.s3_bucket_id}.s3.${data.aws_region.current.name}.amazonaws.com"
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "app-origin"
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.alb.id
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "app-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = var.distribution_comment
  }
}

# S3 Bucket Policy for CloudFront OAC
resource "aws_s3_bucket_policy" "cloudfront" {
  bucket = var.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontServicePrincipal"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${var.s3_bucket_arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}
