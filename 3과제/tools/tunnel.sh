#!/usr/bin/env bash
# CloudShell에서 Flask 대시보드를 브라우저로 보기: cloudflared 터널 + 접속주소 출력.
# 사용:  bash tunnel.sh
#        PORT=8080 NS=app WAF=aws-waf-logs-wsi2026b bash tunnel.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-8080}"; NS="${NS:-app}"; WAF="${WAF:-aws-waf-logs-wsi2026b}"
mkdir -p "$HOME/bin"

if [ ! -x "$HOME/bin/cloudflared" ]; then
  echo "cloudflared 설치 중..."
  curl -fsSL -o "$HOME/bin/cloudflared" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$HOME/bin/cloudflared"
fi

if ! curl -s "http://localhost:$PORT/" >/dev/null 2>&1; then
  echo "대시보드 시작 중 (포트 $PORT, ns $NS)..."
  ( cd "$HERE" && python3 dashboard.py --namespace "$NS" --port "$PORT" --waf-log-group "$WAF" >/tmp/dash.log 2>&1 & )
  sleep 4
fi
if ! curl -s "http://localhost:$PORT/" >/dev/null 2>&1; then
  echo "!! 대시보드가 안 떴습니다. 로그: cat /tmp/dash.log  (flask 없으면: pip3 install flask)"; exit 1
fi

CFLOG=/tmp/cloudflared.log
: > "$CFLOG"
"$HOME/bin/cloudflared" tunnel --url "http://localhost:$PORT" >"$CFLOG" 2>&1 &
CFPID=$!
trap 'kill $CFPID 2>/dev/null' EXIT INT TERM

echo "터널 여는 중..."
URL=""
for i in $(seq 1 40); do
  URL=$(grep -Eo 'https://[a-z0-9.-]+\.trycloudflare\.com' "$CFLOG" | head -1 || true)
  [ -n "$URL" ] && break
  kill -0 "$CFPID" 2>/dev/null || { echo "!! cloudflared 종료됨. 로그:"; cat "$CFLOG"; exit 1; }
  sleep 1
done

echo
echo "=================================================================="
if [ -n "$URL" ]; then
  echo "  접속 주소 →  $URL"
  echo "  (이 주소를 노트북 브라우저에 붙여넣으세요. 종료: Ctrl+C)"
else
  echo "  주소를 못 찾았습니다. 로그 확인: cat $CFLOG"
fi
echo "=================================================================="
echo
echo "(연결 로그는 $CFLOG 에 기록됩니다. 종료하려면 Ctrl+C)"
# 주소가 화면에 남도록 로그는 출력하지 않고 터널만 유지
wait "$CFPID"