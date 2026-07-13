# book 앱 이미지
#   - scratch 기반 => OS 패키지 0 => ECR 스캔 취약점 0
#   - book 바이너리: strip + upx 압축으로 경량화
#   - static curl: 컨테이너 내부 curl 실행(채점 6-5)용
#   - ca-certificates: HTTPS(AWS SDK) 용
# 결과 이미지 8MB 이하 목표.
FROM alpine:3.21 AS prep
WORKDIR /out
COPY book /out/app
RUN apk add --no-cache upx binutils ca-certificates curl tar xz \
 && strip /out/app || true \
 && upx -9 /out/app || true \
 # 정적 curl 바이너리 받기 (musl static build)
 && curl -fsSL -o /tmp/curl https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64 \
 && chmod +x /tmp/curl && strip /tmp/curl || true \
 && upx -9 /tmp/curl || true \
 && cp /tmp/curl /out/curl

FROM scratch
COPY --from=prep /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=prep /out/app /app
COPY --from=prep /out/curl /usr/bin/curl
# book 앱은 TCP/8080 바인딩 (Reference02)
EXPOSE 8080
ENTRYPOINT ["/app"]
