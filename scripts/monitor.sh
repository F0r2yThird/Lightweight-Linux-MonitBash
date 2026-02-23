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
SUCCESS_WINDOW_MINUTES="${SUCCESS_WINDOW_MINUTES:-30}"
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

auth_users_csv() {
  local out=""
  local user
  for user in "${AUTH_USERS[@]}"; do
    if [[ -z "$out" ]]; then
      out="$user"
    else
      out="${out},${user}"
    fi
  done
  printf '%s' "$out"
}

get_fail_alert() {
  local user="$1"
  local key var
  key="$(sanitize_user_key "$user")"
  var="FAIL_ALERT_${key}"
  eval "printf '%s' \"\${$var:-0}\""
}

set_fail_alert() {
  local user="$1"
  local value="$2"
  local key var
  key="$(sanitize_user_key "$user")"
  var="FAIL_ALERT_${key}"
  eval "$var=\"$value\""
}

get_last_fails() {
  local user="$1"
  local key var
  key="$(sanitize_user_key "$user")"
  var="LAST_FAILS_${key}"
  eval "printf '%s' \"\${$var:-0}\""
}

set_last_fails() {
  local user="$1"
  local value="$2"
  local key var
  key="$(sanitize_user_key "$user")"
  var="LAST_FAILS_${key}"
  eval "$var=\"$value\""
}

normalize_timezone() {
  local tz_input="$1"
  if [[ "$tz_input" =~ ^UTC([+-])([0-9]{1,2})$ ]]; then
    TZ_SIGN="${BASH_REMATCH[1]}"
    TZ_HOURS="${BASH_REMATCH[2]}"
  else
    TZ_SIGN="+"
    TZ_HOURS="0"
  fi

  if (( TZ_HOURS > 14 )); then
    TZ_HOURS="14"
  fi

  if [[ "$TZ_SIGN" == "+" ]]; then
    TZ_SHIFT_EXPR="+${TZ_HOURS} hours"
  else
    TZ_SHIFT_EXPR="-${TZ_HOURS} hours"
  fi

  TIMEZONE_LABEL="UTC${TZ_SIGN}${TZ_HOURS}"
}

format_epoch() {
  local epoch="$1"
  local formatted

  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "unknown (${TIMEZONE_LABEL})"
    return
  fi

  formatted="$(date -u -d "@${epoch} ${TZ_SHIFT_EXPR}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  if [[ -z "$formatted" ]]; then
    printf '%s' "${epoch} (${TIMEZONE_LABEL})"
    return
  fi

  printf '%s' "${formatted} ${TIMEZONE_LABEL}"
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

collect_failed_counts() {
  local users_csv cutoff user
  users_csv="$(auth_users_csv)"

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --since "-${AUTH_WINDOW_MINUTES} min" --no-pager -o short-unix 2>/dev/null \
      | awk -v users="$users_csv" '
          BEGIN {
            n = split(users, arr, ",");
            for (i = 1; i <= n; i++) { target[arr[i]] = 1; count[arr[i]] = 0; }
          }
          {
            if (match($0, /Failed password for (invalid user )?([^ ]+) from /, m)) {
              user = m[2];
              if (user in target) count[user]++;
            }
          }
          END {
            for (u in target) print u "|" count[u];
          }
        '
    return
  fi

  if [[ -f /var/log/auth.log ]]; then
    cutoff="$(date -d "-${AUTH_WINDOW_MINUTES} minutes" +%s)"
    awk -v users="$users_csv" -v cutoff="$cutoff" '
      BEGIN {
        months["Jan"]=1; months["Feb"]=2; months["Mar"]=3; months["Apr"]=4;
        months["May"]=5; months["Jun"]=6; months["Jul"]=7; months["Aug"]=8;
        months["Sep"]=9; months["Oct"]=10; months["Nov"]=11; months["Dec"]=12;
        n = split(users, arr, ",");
        for (i = 1; i <= n; i++) { target[arr[i]] = 1; count[arr[i]] = 0; }
      }
      {
        mon = months[$1]; day = $2 + 0;
        split($3, t, ":"); year = strftime("%Y");
        ts = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, t[1], t[2], t[3]));
        if (ts >= cutoff && match($0, /Failed password for (invalid user )?([^ ]+) from /, m)) {
          user = m[2];
          if (user in target) count[user]++;
        }
      }
      END {
        for (u in target) print u "|" count[u];
      }
    ' /var/log/auth.log 2>/dev/null
    return
  fi

  for user in "${AUTH_USERS[@]}"; do
    printf '%s|0\n' "$user"
  done
}

collect_success_events() {
  local users_csv cutoff
  users_csv="$(auth_users_csv)"

  if command -v journalctl >/dev/null 2>&1; then
    journalctl --since "-${SUCCESS_WINDOW_MINUTES} min" --no-pager -o short-unix 2>/dev/null \
      | awk -v users="$users_csv" '
          BEGIN {
            n = split(users, arr, ",");
            for (i = 1; i <= n; i++) target[arr[i]] = 1;
          }
          {
            if (match($0, /Accepted (password|publickey|keyboard-interactive\/pam) for ([^ ]+) from ([^ ]+)/, m)) {
              user = m[2]; ip = m[3];
              if (user in target) {
                split($1, ts, "."); epoch = ts[1] + 0;
                safe_user = user; gsub(/[^0-9A-Za-z]/, "_", safe_user);
                safe_ip = ip; gsub(/[^0-9A-Za-z]/, "_", safe_ip);
                key = epoch "_" safe_user "_" safe_ip;
                print epoch "|" user "|" ip "|" key;
              }
            }
          }
        '
    return
  fi

  if [[ -f /var/log/auth.log ]]; then
    cutoff="$(date -d "-${SUCCESS_WINDOW_MINUTES} minutes" +%s)"
    awk -v users="$users_csv" -v cutoff="$cutoff" '
      BEGIN {
        months["Jan"]=1; months["Feb"]=2; months["Mar"]=3; months["Apr"]=4;
        months["May"]=5; months["Jun"]=6; months["Jul"]=7; months["Aug"]=8;
        months["Sep"]=9; months["Oct"]=10; months["Nov"]=11; months["Dec"]=12;
        n = split(users, arr, ",");
        for (i = 1; i <= n; i++) target[arr[i]] = 1;
      }
      {
        mon = months[$1]; day = $2 + 0;
        split($3, t, ":"); year = strftime("%Y");
        epoch = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, t[1], t[2], t[3]));
        if (epoch >= cutoff && match($0, /Accepted (password|publickey|keyboard-interactive\/pam) for ([^ ]+) from ([^ ]+)/, m)) {
          user = m[2]; ip = m[3];
          if (user in target) {
            safe_user = user; gsub(/[^0-9A-Za-z]/, "_", safe_user);
            safe_ip = ip; gsub(/[^0-9A-Za-z]/, "_", safe_ip);
            key = epoch "_" safe_user "_" safe_ip;
            print epoch "|" user "|" ip "|" key;
          }
        }
      }
    ' /var/log/auth.log 2>/dev/null
  fi
}

process_success_logins() {
  local events last_line event_epoch event_user event_ip event_key matched_last_key

  events="$(collect_success_events || true)"
  [[ -z "$events" ]] && return

  if [[ "$LOGIN_CURSOR_INITIALIZED" != "1" ]]; then
    last_line="$(printf '%s\n' "$events" | tail -n1)"
    IFS='|' read -r event_epoch event_user event_ip event_key <<< "$last_line"
    if [[ -n "$event_epoch" ]]; then
      LOGIN_CURSOR_INITIALIZED=1
      LAST_LOGIN_EPOCH="$event_epoch"
      LAST_LOGIN_KEY="$event_key"
    fi
    return
  fi

  matched_last_key=0
  while IFS='|' read -r event_epoch event_user event_ip event_key; do
    [[ -z "$event_epoch" ]] && continue

    if (( event_epoch < LAST_LOGIN_EPOCH )); then
      continue
    fi

    if (( event_epoch == LAST_LOGIN_EPOCH )); then
      if [[ "$event_key" == "$LAST_LOGIN_KEY" ]]; then
        matched_last_key=1
        continue
      fi
      if [[ "$matched_last_key" != "1" ]]; then
        continue
      fi
    fi

    send_telegram "[info] LOGIN SUCCESS

User: ${event_user}
Time: $(format_epoch "$event_epoch")
Source IP: ${event_ip}"

    LAST_LOGIN_EPOCH="$event_epoch"
    LAST_LOGIN_KEY="$event_key"
  done <<< "$events"
}

{
  user=""
  current_count=0

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

  parse_auth_users
  normalize_timezone "$TIMEZONE_RAW"
  load_state

  current_cpu="$(cpu_percent)"
  current_ram="$(ram_percent)"

  while IFS='|' read -r user current_count; do
    [[ -z "$user" ]] && continue
    set_last_fails "$user" "$current_count"
  done < <(collect_failed_counts)

  if (( current_cpu > CPU_THRESHOLD )); then
    if [[ "$CPU_ALERT_ACTIVE" == "0" ]]; then
      send_telegram "[info] ALERT: CPU

Current: ${current_cpu}%
Threshold: > ${CPU_THRESHOLD}%"
      CPU_ALERT_ACTIVE=1
    fi
  else
    CPU_ALERT_ACTIVE=0
  fi

  if (( current_ram > RAM_THRESHOLD )); then
    if [[ "$RAM_ALERT_ACTIVE" == "0" ]]; then
      send_telegram "[info] ALERT: RAM

Current: ${current_ram}%
Threshold: > ${RAM_THRESHOLD}%"
      RAM_ALERT_ACTIVE=1
    fi
  else
    RAM_ALERT_ACTIVE=0
  fi

  for user in "${AUTH_USERS[@]}"; do
    current_count="$(get_last_fails "$user")"
    if (( current_count >= FAIL_THRESHOLD )); then
      if [[ "$(get_fail_alert "$user")" == "0" ]]; then
        send_telegram "[info] ALERT: Auth failures (${user})

Current: ${current_count} failed attempts in last ${AUTH_WINDOW_MINUTES} min
Threshold: >= ${FAIL_THRESHOLD}"
        set_fail_alert "$user" "1"
      fi
    else
      set_fail_alert "$user" "0"
    fi
  done

  process_success_logins

  LAST_CPU="$current_cpu"
  LAST_RAM="$current_ram"
  LAST_TS="$(date +%s)"

  save_state
}
