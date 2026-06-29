#!/bin/bash
# rotate Lambda용 Pillow 패키지 빌드 (Linux bash, build.ps1 의 bash 변환본)
# Lambda(python3.14, manylinux) 대상 Pillow 휠을 lambda/rotate_pkg 에 설치한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$SCRIPT_DIR/lambda/rotate_pkg"

echo "=== Pillow 패키지 빌드 ==="
rm -rf "$PKG"
mkdir -p "$PKG"

cp "$SCRIPT_DIR/lambda/rotate.py" "$PKG/"

python3 -m pip install \
  --platform manylinux2014_x86_64 \
  --target "$PKG" \
  --implementation cp \
  --python-version 3.14 \
  --only-binary=:all: \
  Pillow

echo "=== 빌드 완료: $PKG ==="
