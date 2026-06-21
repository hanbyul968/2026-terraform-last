# Go 정적 바이너리(book)용 최소 이미지.
# scratch 기반 -> OS 패키지 0개 -> ECR 스캔 CRITICAL/HIGH 0 보장.
# DynamoDB(HTTPS) 호출을 위해 CA 인증서만 복사한다.
FROM public.ecr.aws/docker/library/alpine:3.21 AS certs
RUN apk add --no-cache ca-certificates

FROM scratch
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
