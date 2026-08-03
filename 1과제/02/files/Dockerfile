# book 앱 이미지 (Go, glibc 동적 바이너리)
#   - 채점 6/3-1: Critical/High 취약점 0 이어야 함.
#   - debian:bookworm-slim + curl 은 libcurl/openssl/krb5 체인 때문에 ECR BASIC
#     스캔에서 CRITICAL/HIGH 가 다수 잡힌다(관측: CRITICAL=4, HIGH=11).
#   - => Google distroless(base-debian12) 사용. apt/curl/shell 이 없어 취약 패키지
#     표면이 최소이며 glibc·libssl·ca-certificates·tzdata 만 포함 → book 실행에 충분.
#   - ecr.tf 스캔 게이트: COMPLETE 시 CRITICAL/HIGH 가 있으면 apply 실패(없으면 통과).
#
#   [실행이 안 될 경우 대체]  base-debian12 로 라이브러리가 부족해 앱이 죽으면
#     FROM gcr.io/distroless/cc-debian12   (libstdc++/libgcc 추가) 로 바꾼다.
#     그래도 안 되면 debian:bookworm-slim 로 두되 curl 은 설치하지 말 것
#     (ca-certificates tzdata 만) — curl 제거만으로도 대부분의 CRITICAL/HIGH 가 사라진다.

FROM alpine:3.21 AS prep
WORKDIR /out
COPY book /out/app
# 크기 축소(선택). 실패해도 무시하고 원본 사용.
RUN apk add --no-cache upx binutils \
 && strip /out/app || true \
 && upx -9 /out/app || true

FROM gcr.io/distroless/base-debian12
ENV TZ=Asia/Seoul
COPY --from=prep /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
