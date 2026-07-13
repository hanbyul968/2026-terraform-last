FROM public.ecr.aws/docker/library/alpine:3.20
RUN apk add --no-cache curl
COPY bootstrap.sh /bootstrap.sh
RUN sed -i 's/\r$//' /bootstrap.sh && chmod +x /bootstrap.sh
ENTRYPOINT ["/bootstrap.sh"]
