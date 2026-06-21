FROM alpine:latest
ENV AWS_REGION=ap-northeast-2
ENV TABLE_NAME=unicorn-concert-db
RUN apk add --no-cache ca-certificates libc6-compat
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
