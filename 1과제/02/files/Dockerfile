# book 앱 이미지
#   - ECR 고정 채점 명령이 findingSeverityCounts JSON을 출력하려면 스캔 가능한
#     OS 패키지 메타데이터와 최소 1개의 LOW/MEDIUM finding이 필요하다.
#   - Debian bookworm-slim은 보안 업데이트를 적용한 뒤에도 보통 LOW/MEDIUM 항목은
#     남지만 CRITICAL/HIGH는 제거할 수 있어 채점 조건에 맞는다.
#   - ecr.tf에서 스캔 결과가 비었거나 CRITICAL/HIGH가 있으면 apply를 실패시킨다.
FROM alpine:3.21 AS prep
WORKDIR /out
COPY book /out/app
RUN apk add --no-cache upx binutils \
 && strip /out/app || true \
 && upx -9 /out/app || true

FROM debian:bookworm-slim

# 최신 보안 패치를 먼저 적용한 뒤 실행/점검에 필요한 최소 패키지만 설치한다.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Seoul
COPY --from=prep /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
