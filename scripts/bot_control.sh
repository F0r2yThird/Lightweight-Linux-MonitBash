#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BOT_TOKEN:?BOT_TOKEN is required}"
: "${CHAT_ID:?CHAT_ID is required}"

CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
RAM_THRESHOLD="${RAM_THRESHOLD:-90}"
ROOT_FAIL_THRESHOLD="${ROOT_FAIL_THRESHOLD:-5}"
ROOT_WINDOW_MINUTES="${ROOT_WINDOW_MINUTES:-5}"
STATE_FILE="${STATE_FILE:-/var/tmp/tg_monitor_state.env}"
LOCK_FILE="${LOCK_FILE:-/var/tmp/tg_monitor.lock}"
LOCK_DIR="${LOCK_FILE}.d"

mkdir -p "$(dirname "$STATE_FILE")"

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  ALERTING_ENABLED="${ALERTING_ENABLED:-1}"
  CPU_ALERT_ACTIVE="${CPU_ALERT_ACTIVE:-0}"
  RAM_ALERT_ACTIVE="${RAM_ALERT_ACTIVE:-0}"
  ROOT_ALERT_ACTIVE="${ROOT_ALERT_ACTIVE:-0}"
  LAST_CPU="${LAST_CPU:-0}"
  LAST_RAM="${LAST_RAM:-0}"
  LAST_ROOT_FAILS="${LAST_ROOT_FAILS:-0}"
  LAST_TS="${LAST_TS:-0}"
  TG_OFFSET="${TG_OFFSET:-0}"
}

save_state() {
  local tmp_file
  tmp_file="$(mktemp "${STATE_FILE}.XXXXXX")"
  cat > "$tmp_file" <<STATE
ALERTING_ENABLED=${ALERTING_ENABLED}
CPU_ALERT_ACTIVE=${CPU_ALERT_ACTIVE}
RAM_ALERT_ACTIVE=${RAM_ALERT_ACTIVE}
ROOT_ALERT_ACTIVE=${ROOT_ALERT_ACTIVE}
LAST_CPU=${LAST_CPU}
LAST_RAM=${LAST_RAM}
LAST_ROOT_FAILS=${LAST_ROOT_FAILS}
LAST_TS=${LAST_TS}
TG_OFFSET=${TG_OFFSET}
STATE
  mv "$tmp_file" "$STATE_FILE"
}

send_telegram() {
  local text="$1"
  curl -sS -m 15 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${text}" \
    > /dev/null
}

parse_update() {
  local json="$1"
  python3 -c '
import json
import sys

try:
    payload = json.loads(sys.stdin.read())
    results = payload.get("result") or []
    if not results:
        print("|||")
        raise SystemExit(0)
    item = results[0]
    update_id = item.get("update_id", "")
    msg = item.get("message") or {}
    chat = msg.get("chat") or {}
    chat_id = chat.get("id", "")
    text = msg.get("text", "")
    print(f"{update_id}|{chat_id}|{text}")
except Exception:
    print("|||")
' <<< "$json"
}

build_status_text() {
  local enabled_text ts_text

  if [[ "$ALERTING_ENABLED" == "1" ]]; then
    enabled_text="ON"
  else
    enabled_text="OFF"
  fi

  if [[ "$LAST_TS" -gt 0 ]]; then
    ts_text="$(date -d "@$LAST_TS" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$LAST_TS")"
  else
    ts_text="no data yet"
  fi

  printf '%s' "[info] Monitoring status:
Alerting: ${enabled_text}
Last metrics: CPU=${LAST_CPU}%%, RAM=${LAST_RAM}%%, root_failed_5m=${LAST_ROOT_FAILS}
Thresholds: CPU>${CPU_THRESHOLD}%%, RAM>${RAM_THRESHOLD}%%, root_failed_5m>=${ROOT_FAIL_THRESHOLD}
Last update: ${ts_text}"
}

{
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  load_state

  response="$(curl -sS -m 20 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" \
    --get \
    --data-urlencode "offset=${TG_OFFSET}" \
    --data-urlencode "limit=1" \
    --data-urlencode "timeout=0" \
    --data-urlencode 'allowed_updates=["message"]')"

  parsed_line="$(parse_update "$response")"
  IFS='|' read -r update_id incoming_chat_id command <<< "$parsed_line"

  if [[ -z "$update_id" ]]; then
    save_state
    exit 0
  fi

  TG_OFFSET=$((update_id + 1))

  if [[ "$incoming_chat_id" != "$CHAT_ID" ]]; then
    save_state
    exit 0
  fi

  case "$command" in
    /off)
      ALERTING_ENABLED=0
      send_telegram "[info] Alerting disabled"
      ;;
    /on)
      ALERTING_ENABLED=1
      send_telegram "[info] Alerting enabled"
      ;;
    /status)
      send_telegram "$(build_status_text)"
      ;;
    *)
      ;;
  esac

  save_state
}
