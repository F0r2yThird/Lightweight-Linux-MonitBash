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

  if [[ "$ALERTING_ENABLED" != "1" ]]; then
    return 0
  fi

  curl -sS -m 15 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${text}" \
    > /dev/null
}

cpu_percent() {
  local cpu_line1 cpu_line2
  local user1 nice1 sys1 idle1 iowait1 irq1 softirq1 steal1
  local user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2
  local total1 total2 totald idled usage

  cpu_line1="$(grep '^cpu ' /proc/stat 2>/dev/null || true)"
  if [[ -z "$cpu_line1" ]]; then
    echo 0
    return
  fi
  read -r _ user1 nice1 sys1 idle1 iowait1 irq1 softirq1 steal1 _ < <(printf '%s\n' "$cpu_line1")

  sleep 1

  cpu_line2="$(grep '^cpu ' /proc/stat 2>/dev/null || true)"
  if [[ -z "$cpu_line2" ]]; then
    echo 0
    return
  fi
  read -r _ user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2 _ < <(printf '%s\n' "$cpu_line2")

  total1=$((user1 + nice1 + sys1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
  total2=$((user2 + nice2 + sys2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
  totald=$((total2 - total1))
  idled=$((idle2 - idle1))

  if (( totald <= 0 )); then
    echo 0
    return
  fi

  usage=$(( (100 * (totald - idled)) / totald ))
  echo "$usage"
}

ram_percent() {
  local mem_total mem_available mem_used
  mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  mem_available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"

  if [[ -z "$mem_total" || -z "$mem_available" || "$mem_total" -eq 0 ]]; then
    echo 0
    return
  fi

  mem_used=$((mem_total - mem_available))
  echo $(( (100 * mem_used) / mem_total ))
}

root_failed_attempts() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --since "-${ROOT_WINDOW_MINUTES} min" --no-pager 2>/dev/null \
      | grep -c 'Failed password for root' || true
    return
  fi

  if [[ -f /var/log/auth.log ]]; then
    local cutoff
    cutoff="$(date -d "-${ROOT_WINDOW_MINUTES} minutes" +%s)"
    awk -v cutoff="$cutoff" '
      BEGIN {
        months["Jan"]=1; months["Feb"]=2; months["Mar"]=3; months["Apr"]=4;
        months["May"]=5; months["Jun"]=6; months["Jul"]=7; months["Aug"]=8;
        months["Sep"]=9; months["Oct"]=10; months["Nov"]=11; months["Dec"]=12;
        count=0;
      }
      /Failed password for root/ {
        mon = months[$1];
        day = $2 + 0;
        split($3, t, ":");
        year = strftime("%Y");
        ts = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, t[1], t[2], t[3]));
        if (ts >= cutoff) {
          count++;
        }
      }
      END { print count }
    ' /var/log/auth.log 2>/dev/null || true
    return
  fi

  echo 0
}

{
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  load_state

  current_cpu="$(cpu_percent)"
  current_ram="$(ram_percent)"
  current_root_fails="$(root_failed_attempts)"

  if (( current_cpu > CPU_THRESHOLD )); then
    if [[ "$CPU_ALERT_ACTIVE" == "0" ]]; then
      send_telegram "[info] CPU high: ${current_cpu}% (threshold: >${CPU_THRESHOLD}%)"
      CPU_ALERT_ACTIVE=1
    fi
  else
    CPU_ALERT_ACTIVE=0
  fi

  if (( current_ram > RAM_THRESHOLD )); then
    if [[ "$RAM_ALERT_ACTIVE" == "0" ]]; then
      send_telegram "[info] RAM high: ${current_ram}% (threshold: >${RAM_THRESHOLD}%)"
      RAM_ALERT_ACTIVE=1
    fi
  else
    RAM_ALERT_ACTIVE=0
  fi

  if (( current_root_fails >= ROOT_FAIL_THRESHOLD )); then
    if [[ "$ROOT_ALERT_ACTIVE" == "0" ]]; then
      send_telegram "[info] Root failed auth attempts: ${current_root_fails} in ${ROOT_WINDOW_MINUTES} min (threshold: >=${ROOT_FAIL_THRESHOLD})"
      ROOT_ALERT_ACTIVE=1
    fi
  else
    ROOT_ALERT_ACTIVE=0
  fi

  LAST_CPU="$current_cpu"
  LAST_RAM="$current_ram"
  LAST_ROOT_FAILS="$current_root_fails"
  LAST_TS="$(date +%s)"

  save_state
}
