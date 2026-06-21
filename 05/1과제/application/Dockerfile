FROM alpine:3.20 AS prep
COPY book* /app
RUN chmod +x /app && apk add --no-cache upx binutils ca-certificates && strip /app && upx --brute /app

FROM scratch
COPY --from=prep /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=prep /app /app
ENTRYPOINT ["/app"]
