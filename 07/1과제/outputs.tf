output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "alb_dns" {
  value = aws_lb.main.dns_name
}
