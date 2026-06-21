FROM gcr.io/distroless/static-debian12:nonroot
ARG APP
COPY --chmod=0755 ${APP} /app
EXPOSE 8080
ENTRYPOINT ["/app"]
