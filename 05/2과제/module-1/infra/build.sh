#!/bin/bash
# rotate Lambda용 Pillow 패키지 빌드 (CloudShell/Linux에서 실행)
# terraform apply 전에 반드시 실행할 것

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/lambda/rotate_pkg"

echo "=== Pillow 패키지 빌드 ==="
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# rotate.py 복사
cp "$SCRIPT_DIR/lambda/rotate.py" "$PKG_DIR/"

# Pillow 설치 (Lambda Linux 환경 대상)
pip3 install \
  --platform manylinux2014_x86_64 \
  --target "$PKG_DIR" \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  Pillow

echo "=== 빌드 완료: $PKG_DIR ==="
echo "이제 terraform apply -var pin=<비번호> 실행"
