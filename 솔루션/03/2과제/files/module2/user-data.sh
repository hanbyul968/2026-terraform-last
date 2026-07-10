#!/bin/bash
# wsc2026-keycloak EC2 (Amazon Linux 2023, t3.medium, private subnet)
# ALB(HTTP:80) → EC2(HTTP:8080)
set -eux

dnf update -y
dnf install -y docker
systemctl enable --now docker

docker run -d --name keycloak --restart always \
  -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME='admin' \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD='Skill53#!!@#' \
  -e KC_HTTP_ENABLED=true \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_PROXY_HEADERS=xforwarded \
  quay.io/keycloak/keycloak:26.0 \
  start-dev

# 기동 확인: curl -s -o /dev/null -w '%{http_code}' localhost:8080/realms/master  → 200
