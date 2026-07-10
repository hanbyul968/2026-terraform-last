#!/usr/bin/env bash
# Lambda@Edge 는 Layer 를 못 쓰므로 Pillow 를 zip 안에 함께 넣어야 한다.
# CloudShell(us-east-1) 에서 실행 → wsc2026-resize.zip 생성
set -euo pipefail

rm -rf build wsc2026-resize.zip
mkdir -p build

# Lambda python3.12 = manylinux2014_x86_64
pip install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target build \
  Pillow

cp lambda_function.py build/
cd build && zip -qr ../wsc2026-resize.zip . && cd ..

echo "생성 완료: $(pwd)/wsc2026-resize.zip"
echo "50MB 초과 시 S3 업로드 후 --code S3Bucket=...,S3Key=... 로 배포"
