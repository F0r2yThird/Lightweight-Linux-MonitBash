#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/tg-monitor}"
CRON_TAG="# tg-monitor"

if [[ "$(id -u)" -eq 0 ]]; then
  CRONTAB_CMD="crontab"
else
  CRONTAB_CMD="sudo crontab"
fi

current_cron="$($CRONTAB_CMD -l 2>/dev/null || true)"
clean_cron="$(printf '%s\n' "$current_cron" | grep -v "$CRON_TAG" || true)"
printf '%s\n' "$clean_cron" | $CRONTAB_CMD -

echo "Removed tg-monitor cron entries."

echo "Project files kept in $INSTALL_DIR"
echo "To remove files manually: sudo rm -rf $INSTALL_DIR"
