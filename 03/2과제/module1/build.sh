#!/bin/bash
# wsc2026-resize Lambda@Edge 패키지 빌드 (Linux bash)
#   - Lambda(python3.12, manylinux) 대상 Pillow 휠 + resize.py 를 lambda/resize_pkg 에 설치한다.
#   - data.archive_file.resize 가 resize_pkg 를 zip 으로 묶는다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SCRIPT_DIR/lambda/resize_pkg"

echo "=== wsc2026-resize Pillow 패키지 빌드 ==="
rm -rf "$PKG"
mkdir -p "$PKG"

cp "$SCRIPT_DIR/lambda/resize.py" "$PKG/"

python3 -m pip install \
  --platform manylinux2014_x86_64 \
  --target "$PKG" \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  Pillow

echo "=== 빌드 완료: $PKG ==="
