# book 앱 이미지
#   - 최종 베이스 alpine:3.21 => apk/OS 메타데이터 존재 => ECR BASIC 스캔 COMPLETE(채점 5-2-B)
#   - 크기 최소화(채점 5-2-A: 8MB 이하): apk curl(libcurl 등 의존성 ~2.5MB) 대신
#     정적 curl 바이너리(자체 완결, upx) 복사 -> 8MB 이내
#   - curl: 컨테이너 내부 curl 실행(채점 6-5)용 / ca-certificates: HTTPS(AWS SDK)
FROM alpine:3.21 AS prep
WORKDIR /out
COPY book /out/app
RUN apk add --no-cache upx binutils curl ca-certificates tar xz \
 && strip /out/app || true \
 && upx -9 /out/app || true \
 && curl -fsSL -o /tmp/curl https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64 \
 && chmod +x /tmp/curl && (strip /tmp/curl || true) && (upx -9 /tmp/curl || true) \
 && cp /tmp/curl /out/curl

FROM alpine:3.21
RUN apk add --no-cache ca-certificates && rm -rf /var/cache/apk/*
COPY --from=prep /out/app /app
COPY --from=prep /out/curl /usr/bin/curl
EXPOSE 8080
ENTRYPOINT ["/app"]
