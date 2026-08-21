# tzdata 는 빌더에서만 설치하고 Asia/Seoul zone 파일만 런타임으로 복사한다.
# (런타임 패키지 구성을 그대로 유지 -> ECR 스캔 표면 증가 없음)
FROM public.ecr.aws/docker/library/alpine:3.20 AS tz
RUN apk add --no-cache tzdata

FROM public.ecr.aws/docker/library/alpine:3.20
RUN apk add --no-cache ca-certificates libc6-compat

# 과제 8: 모든 노드의 시간대는 KST. book 은 Go log 패키지의 기본 prefix
# ("2006/01/02 15:04:05", local time)로 access 로그를 찍고 fluent-bit 이 그대로
# timestamp 로 옮기므로, 컨테이너 TZ 가 UTC 면 채점 12-1-A 에서 9시간 차가 난다.
# created_at 은 앱이 .UTC() 로 직접 포맷하므로 이 설정의 영향을 받지 않는다.
COPY --from=tz /usr/share/zoneinfo/Asia/Seoul /usr/share/zoneinfo/Asia/Seoul
COPY --from=tz /usr/share/zoneinfo/Asia/Seoul /etc/localtime
ENV TZ=Asia/Seoul

COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
