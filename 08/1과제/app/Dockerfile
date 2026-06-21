# 지급된 book 실행 파일(Linux/AMD64, Go/Gin)을 컨테이너화한다.
# glibc 동적 링크 가능성을 고려해 debian-slim 기반 사용.
FROM public.ecr.aws/docker/library/debian:bookworm-slim

# 인증서 등 런타임 의존성 (AWS SDK HTTPS 호출용)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY book /app/book
RUN chmod +x /app/book

EXPOSE 8080

ENTRYPOINT ["/app/book"]
