#!/bin/sh
set -eu

# IMDSv2 token + instance-id (부팅 직후 IMDS 지연 대비 재시도)
IMDS=http://169.254.169.254/latest
TOKEN=$(curl -sS --retry 5 --retry-delay 2 --retry-connrefused -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" "$IMDS/api/token")
IID=$(curl -sS --retry 5 --retry-delay 2 --retry-connrefused -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/instance-id")

# role (addon|app) passed via this bootstrap container's user-data
# (set -e 에서 안전하도록 short-circuit 대신 파라미터 기본값 사용)
ROLE=$(cat /.bottlerocket/bootstrap-containers/current/user-data 2>/dev/null | tr -d '[:space:]')
ROLE=${ROLE:-node}

SOCK=/run/api.sock
NAME="gj2026.${IID}.${ROLE}.node"

# stage hostname-override, then commit+apply so kubelet picks it up
curl -sS --unix-socket "$SOCK" -X PATCH -H "Content-Type: application/json" \
  -d "{\"kubernetes\":{\"hostname-override\":\"${NAME}\"}}" \
  http://localhost/settings
curl -sS --unix-socket "$SOCK" -X POST \
  http://localhost/tx/commit_and_apply

echo "hostname-override set to ${NAME}"
