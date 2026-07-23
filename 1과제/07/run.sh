#!/bin/bash
set -Eeuo pipefail
UNIT="unicorn-task1-terraform"

if sudo systemctl is-active --quiet "$UNIT"; then
  echo "Terraform apply is already running in $UNIT. Following logs..."
else
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  sudo systemd-run \
    --unit="$UNIT" \
    --collect \
    --property=Type=exec \
    --property=TimeoutStartSec=infinity \
    /bin/bash /opt/task1/terraform-apply-worker.sh
  echo "Started $UNIT. The apply will survive SSM disconnection."
fi

echo "Reconnect command: sudo journalctl -fu $UNIT"
sudo journalctl -fu "$UNIT"
