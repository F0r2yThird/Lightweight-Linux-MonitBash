#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi
INSTALL_DIR="${INSTALL_DIR:-/opt/tg-monitor}"
TARGET_ENV="$INSTALL_DIR/.env"
CRON_TAG="# tg-monitor"

if [[ ! -f "$SCRIPT_DIR/scripts/monitor.sh" || ! -f "$SCRIPT_DIR/scripts/bot_control.sh" ]]; then
  REPO_URL="${REPO_URL:-https://github.com/F0r2yThird/Lightweight-Linux-MonitBash.git}"
  TMP_DIR="$(mktemp -d /tmp/tg-monitor.XXXXXX)"
  if [[ "${KEEP_TMP:-0}" != "1" ]]; then
    trap 'rm -rf "$TMP_DIR"' EXIT
  fi

  if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y git >/dev/null
    else
      echo "git is required for one-liner install." >&2
      exit 1
    fi
  fi

  git clone "$REPO_URL" "$TMP_DIR" >/dev/null 2>&1
  SCRIPT_DIR="$TMP_DIR"
fi

ENV_TEMPLATE="$SCRIPT_DIR/.env.example"
if [[ ! -f "$ENV_TEMPLATE" ]]; then
  echo "Missing .env.example" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y curl python3 >/dev/null
fi

sudo mkdir -p "$INSTALL_DIR"
sudo cp -r "$SCRIPT_DIR/scripts" "$INSTALL_DIR/"
sudo cp "$ENV_TEMPLATE" "$INSTALL_DIR/.env.example"
if [[ -f "$SCRIPT_DIR/uninstall.sh" ]]; then
  sudo cp "$SCRIPT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
  sudo chmod +x "$INSTALL_DIR/uninstall.sh"
fi

if [[ ! -f "$TARGET_ENV" ]]; then
  sudo cp "$ENV_TEMPLATE" "$TARGET_ENV"
  echo "Created $TARGET_ENV from template."
fi

sudo chmod +x "$INSTALL_DIR/scripts/monitor.sh" "$INSTALL_DIR/scripts/bot_control.sh"

if [[ "$(id -u)" -eq 0 ]]; then
  CRONTAB_CMD="crontab"
else
  CRONTAB_CMD="sudo crontab"
fi

current_cron="$($CRONTAB_CMD -l 2>/dev/null || true)"
clean_cron="$(printf '%s\n' "$current_cron" | grep -v "$CRON_TAG" || true)"

monitor_line="* * * * * ENV_FILE=$TARGET_ENV $INSTALL_DIR/scripts/monitor.sh >/dev/null 2>&1 $CRON_TAG"
bot_line="* * * * * ENV_FILE=$TARGET_ENV $INSTALL_DIR/scripts/bot_control.sh >/dev/null 2>&1 $CRON_TAG"

if printf '%s\n' "$current_cron" | grep -Fq "$monitor_line"; then
  monitor_line=""
fi
if printf '%s\n' "$current_cron" | grep -Fq "$bot_line"; then
  bot_line=""
fi

printf '%s\n%s\n%s\n' "$clean_cron" "$monitor_line" "$bot_line" | $CRONTAB_CMD -

echo ""
echo "Installation complete."
echo "1) Edit config: sudo nano $TARGET_ENV"
echo "2) Set BOT_TOKEN, CHAT_ID and AUTH_USERS"
echo "3) Test manually: ENV_FILE=$TARGET_ENV $INSTALL_DIR/scripts/monitor.sh"
