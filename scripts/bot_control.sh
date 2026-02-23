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
FAIL_THRESHOLD="${ROOT_FAIL_THRESHOLD:-5}"
AUTH_WINDOW_MINUTES="${ROOT_WINDOW_MINUTES:-5}"
TIMEZONE_RAW="${TIMEZONE:-UTC+0}"
AUTH_USERS_RAW="${AUTH_USERS:-root}"
STATE_FILE="${STATE_FILE:-/var/tmp/tg_monitor_state.env}"
LOCK_FILE="${LOCK_FILE:-/var/tmp/tg_monitor.lock}"
LOCK_DIR="${LOCK_FILE}.d"

mkdir -p "$(dirname "$STATE_FILE")"

declare -a AUTH_USERS

trim_value() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

sanitize_user_key() {
  local username="$1"
  local key
  key="$(printf '%s' "$username" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  key="${key#__}"
  key="${key%%__}"
  if [[ -z "$key" ]]; then
    key="USER"
  fi
  if [[ "$key" =~ ^[0-9] ]]; then
    key="U_${key}"
  fi
  printf '%s' "$key"
}

parse_auth_users() {
  local raw entry user found existing
  IFS=',' read -r -a raw <<< "$AUTH_USERS_RAW"

  AUTH_USERS=()
  for entry in "${raw[@]}"; do
    user="$(trim_value "$entry")"
    [[ -z "$user" ]] && continue

    found=0
    for existing in "${AUTH_USERS[@]:-}"; do
      if [[ "$existing" == "$user" ]]; then
        found=1
        break
      fi
    done

    if [[ "$found" == "0" ]]; then
      AUTH_USERS+=("$user")
    fi
  done

  if (( ${#AUTH_USERS[@]} == 0 )); then
    AUTH_USERS=("root")
  fi
}

get_fail_alert() {
  local user="$1" key var
  key="$(sanitize_user_key "$user")"
  var="FAIL_ALERT_${key}"
  eval "printf '%s' \"\${$var:-0}\""
}

set_fail_alert() {
  local user="$1" value="$2" key var
  key="$(sanitize_user_key "$user")"
  var="FAIL_ALERT_${key}"
  eval "$var=\"$value\""
}

get_last_fails() {
  local user="$1" key var
  key="$(sanitize_user_key "$user")"
  var="LAST_FAILS_${key}"
  eval "printf '%s' \"\${$var:-0}\""
}

set_last_fails() {
  local user="$1" value="$2" key var
  key="$(sanitize_user_key "$user")"
  var="LAST_FAILS_${key}"
  eval "$var=\"$value\""
}

format_last_ts() {
  if (( LAST_TS <= 0 )); then
    printf '%s' "no data yet"
    return
  fi

  if [[ "$TIMEZONE_RAW" =~ ^UTC([+-])([0-9]{1,2})$ ]]; then
    local sign hours ts adjusted offset_seconds
    sign="${BASH_REMATCH[1]}"
    hours="${BASH_REMATCH[2]}"
    if (( hours > 14 )); then
      hours="14"
    fi

    if [[ "$sign" == "+" ]]; then
      offset_seconds=$((hours * 3600))
    else
      offset_seconds=$((-hours * 3600))
    fi

    adjusted=$((LAST_TS + offset_seconds))
    ts="$(date -u -d "@${adjusted}" '+%H:%M:%S' 2>/dev/null || true)"
    if [[ -n "$ts" ]]; then
      printf '%s' "${ts} UTC${sign}${hours}"
      return
    fi
  fi

  date -d "@${LAST_TS}" '+%H:%M:%S' 2>/dev/null || printf '%s' "$LAST_TS"
}

load_state() {
  local user

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  ALERTING_ENABLED="${ALERTING_ENABLED:-1}"
  CPU_ALERT_ACTIVE="${CPU_ALERT_ACTIVE:-0}"
  RAM_ALERT_ACTIVE="${RAM_ALERT_ACTIVE:-0}"
  LAST_CPU="${LAST_CPU:-0}"
  LAST_RAM="${LAST_RAM:-0}"
  LAST_TS="${LAST_TS:-0}"
  TG_OFFSET="${TG_OFFSET:-0}"
  LOGIN_CURSOR_INITIALIZED="${LOGIN_CURSOR_INITIALIZED:-0}"
  LAST_LOGIN_EPOCH="${LAST_LOGIN_EPOCH:-0}"
  LAST_LOGIN_KEY="${LAST_LOGIN_KEY:-}"

  for user in "${AUTH_USERS[@]}"; do
    set_fail_alert "$user" "$(get_fail_alert "$user")"
    set_last_fails "$user" "$(get_last_fails "$user")"
  done
}

save_state() {
  local tmp_file user key
  tmp_file="$(mktemp "${STATE_FILE}.XXXXXX")"

  {
    printf 'ALERTING_ENABLED=%s\n' "$ALERTING_ENABLED"
    printf 'CPU_ALERT_ACTIVE=%s\n' "$CPU_ALERT_ACTIVE"
    printf 'RAM_ALERT_ACTIVE=%s\n' "$RAM_ALERT_ACTIVE"
    printf 'LAST_CPU=%s\n' "$LAST_CPU"
    printf 'LAST_RAM=%s\n' "$LAST_RAM"
    printf 'LAST_TS=%s\n' "$LAST_TS"
    printf 'TG_OFFSET=%s\n' "$TG_OFFSET"
    printf 'LOGIN_CURSOR_INITIALIZED=%s\n' "$LOGIN_CURSOR_INITIALIZED"
    printf 'LAST_LOGIN_EPOCH=%s\n' "$LAST_LOGIN_EPOCH"
    printf 'LAST_LOGIN_KEY=%s\n' "$LAST_LOGIN_KEY"

    for user in "${AUTH_USERS[@]}"; do
      key="$(sanitize_user_key "$user")"
      printf 'FAIL_ALERT_%s=%s\n' "$key" "$(get_fail_alert "$user")"
      printf 'LAST_FAILS_%s=%s\n' "$key" "$(get_last_fails "$user")"
    done
  } > "$tmp_file"

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
  local enabled_text ts_text cpu_mark ram_mark user mark lines

  if [[ "$ALERTING_ENABLED" == "1" ]]; then
    enabled_text="ON"
  else
    enabled_text="OFF"
  fi

  if (( LAST_CPU > CPU_THRESHOLD )); then
    cpu_mark="🆘"
  else
    cpu_mark="✅"
  fi

  if (( LAST_RAM > RAM_THRESHOLD )); then
    ram_mark="🆘"
  else
    ram_mark="✅"
  fi

  lines=""
  for user in "${AUTH_USERS[@]}"; do
    if (( $(get_last_fails "$user") >= FAIL_THRESHOLD )); then
      mark="🆘"
    else
      mark="✅"
    fi
    lines+="- ${user} failed auth (last ${AUTH_WINDOW_MINUTES} min): $(get_last_fails "$user") ${mark}\\n"
  done

  ts_text="$(format_last_ts)"

  printf '%b' "[info] MONITORING STATUS\n\nAlerting: ${enabled_text}\n\nCurrent metrics:\n- CPU: ${LAST_CPU}% ${cpu_mark}\n- RAM: ${LAST_RAM}% ${ram_mark}\n${lines}\nLast update: ${ts_text}"
}

build_thresholds_text() {
  local user lines
  lines=""
  for user in "${AUTH_USERS[@]}"; do
    lines+="- ${user} failed auth (last ${AUTH_WINDOW_MINUTES} min) >= ${FAIL_THRESHOLD}\\n"
  done

  printf '%b' "[info] THRESHOLDS\n\n- CPU > ${CPU_THRESHOLD}%\n- RAM > ${RAM_THRESHOLD}%\n${lines}"
}

{
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  parse_auth_users
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
      send_telegram "[info] Alerting is now OFF"
      ;;
    /on)
      ALERTING_ENABLED=1
      send_telegram "[info] Alerting is now ON"
      ;;
    /status)
      send_telegram "$(build_status_text)"
      ;;
    /thresholds)
      send_telegram "$(build_thresholds_text)"
      ;;
    *)
      ;;
  esac

  save_state
}
