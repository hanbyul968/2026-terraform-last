# ---------------------------------------------------------------------------
# EC2 인스턴스 역할: SSM(SSH 없이 접속/운영) + CloudWatch Agent(지표/로그 전송)
# 관리형 정책 ARN 만 사용 -> 계정 무관 이식성.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ec2" {
  name = "${local.name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "${local.name}-ec2-role" }
}

resource "aws_iam_role_policy_attachment" "ec2_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.ec2.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# color 바이너리를 S3(아티팩트 버킷)에서 내려받기 위한 최소 권한
resource "aws_iam_role_policy" "artifacts_read" {
  name = "${local.name}-artifacts-read"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
      }
    ]
  })
}
