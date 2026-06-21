#!/usr/bin/env bash
# One-shot bootstrap for AWS CloudShell (Amazon Linux 2023).
# Installs hey + kubectl into ~/bin (persists in home), wires up kubeconfig.
# CloudShell already has: aws CLI, python3, curl, git. Credentials are ambient
# (the account you opened CloudShell in) — NO --profile needed.
#
# Usage:
#   ./cloudshell-setup.sh <eks-cluster-name> [region]
# e.g.
#   ./cloudshell-setup.sh wsi2026-cluster ap-northeast-2
set -euo pipefail
CLUSTER=${1:?usage: cloudshell-setup.sh <cluster> [region]}
REGION=${2:-ap-northeast-2}
mkdir -p "$HOME/bin"

# --- PATH (persist for future CloudShell sessions) ---
case ":$PATH:" in *":$HOME/bin:"*) : ;; *) export PATH="$HOME/bin:$PATH";; esac
grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"

# --- kubectl ---
if ! command -v kubectl >/dev/null 2>&1; then
  echo "installing kubectl..."
  KV=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -L -o "$HOME/bin/kubectl" "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
  chmod +x "$HOME/bin/kubectl"
fi

# --- hey ---
if ! command -v hey >/dev/null 2>&1; then
  echo "installing hey..."
  curl -L -o "$HOME/bin/hey" https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
  chmod +x "$HOME/bin/hey"
fi

# --- kubeconfig (ambient creds, no profile) ---
echo "writing kubeconfig for $CLUSTER ($REGION)..."
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

echo
echo "=== ready ==="
kubectl version --client 2>/dev/null | head -1 || true
hey -h >/dev/null 2>&1 && echo "hey: ok"
python3 --version
echo
echo ">>> 현재 셸에 PATH 적용 (이 줄을 복사해 실행):"
echo "      export PATH=\"\$HOME/bin:\$PATH\""
echo "    (loadtest/autotune 는 내부에서 ~/bin 을 자동 추가하므로 스크립트는 그냥 돌아간다."
echo "     위 export 는 직접 kubectl/hey 를 칠 때만 필요. 새 CloudShell 세션은 .bashrc 로 자동 적용)"
echo
echo "sanity:  kubectl -n app get pods   (PATH 적용 후)"
echo "run:     ./loadtest.sh <endpoint> 180s baseline"
echo "tune:    ./autotune.sh <endpoint> 90s"
