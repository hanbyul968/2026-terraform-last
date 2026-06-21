resource "aws_ecr_repository" "book" {
  name                 = "book"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# public.ecr.aws 미러 (pull-through cache).
# 노드는 NAT 없는 private subnet 이라 public 레지스트리에 직접 접근할 수 없고,
# <account>.dkr.ecr.<region>.amazonaws.com/ecr-public/... 경로로만 pull 가능하다.
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}
