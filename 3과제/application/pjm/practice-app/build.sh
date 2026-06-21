#!/bin/bash
set -euo pipefail

# Build all three apps for linux/amd64 (Amazon Linux 2023 EC2).
# Output: dist/user, dist/product, dist/stress (static, stripped)
#
# Override GOOS/GOARCH if you need a different target:
#   GOARCH=arm64 ./build.sh

GOOS_TARGET="${GOOS:-linux}"
GOARCH_TARGET="${GOARCH:-amd64}"

mkdir -p dist

for app in user product stress; do
  echo ">>> building $app ($GOOS_TARGET/$GOARCH_TARGET)"
  GOOS="$GOOS_TARGET" GOARCH="$GOARCH_TARGET" CGO_ENABLED=0 \
    go -C "${app}-app" build -ldflags="-s -w" -o "../dist/${app}" .
done

echo ""
echo "=== artifacts ==="
ls -lh dist/
echo ""
echo "=== verify ==="
file dist/* 2>/dev/null || true
