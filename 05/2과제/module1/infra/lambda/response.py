# Lambda@Edge: gj2026-cdn-response (origin-response)
# Origin(rotate Lambda)의 응답에 Cache-Control 헤더 보장


def lambda_handler(event, context):
    response = event["Records"][0]["cf"]["response"]

    if "cache-control" not in response["headers"]:
        response["headers"]["cache-control"] = [
            {"key": "Cache-Control", "value": "max-age=86400"}
        ]

    return response
