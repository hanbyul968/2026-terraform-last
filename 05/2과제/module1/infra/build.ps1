# rotate Lambda용 Pillow 패키지 빌드 (Windows PowerShell)
$ErrorActionPreference = "Stop"
$pkg = Join-Path $PSScriptRoot "lambda\rotate_pkg"

Write-Host "=== Pillow 패키지 빌드 ==="
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force $pkg | Out-Null

Copy-Item (Join-Path $PSScriptRoot "lambda\rotate.py") $pkg

# Lambda(python3.12, manylinux) 대상 Pillow 설치
python -m pip install `
  --platform manylinux2014_x86_64 `
  --target $pkg `
  --implementation cp `
  --python-version 3.12 `
  --only-binary=:all: `
  Pillow

Write-Host "=== 빌드 완료: $pkg ==="
