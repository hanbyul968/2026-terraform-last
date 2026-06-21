# Lambda@Edge: gj2026-cdn-request (viewer-request)
# CloudFront → 이 함수 → Origin(rotate Lambda Function URL)
# 쿼리 파라미터(image, rotate)를 그대로 Origin으로 전달


def lambda_handler(event, context):
    request = event["Records"][0]["cf"]["request"]
    # 경로를 /images 에서 / 로 변환 (rotate Lambda는 / 에서 처리)
    # querystring은 CloudFront cache policy에 의해 자동 포함됨
    request["uri"] = "/"
    return request
