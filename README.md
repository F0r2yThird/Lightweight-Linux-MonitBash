# TG Linux Monitor

[Русская версия](README.ru.md)

Lightweight Linux monitoring with Telegram alerts. Designed for low-resource servers (for example, 1 GB RAM).

## Features

- CPU usage alert (`CPU_THRESHOLD`)
- RAM usage alert (`RAM_THRESHOLD`)
- Failed auth attempts per user in a rolling window (`ROOT_FAIL_THRESHOLD` in `ROOT_WINDOW_MINUTES`)
- Success login alert for each new SSH login event (with user, time, source IP)
- Telegram bot controls:
  - `/on`
  - `/off`
  - `/status`
  - `/thresholds`
- Single state file (rewritten, no DB)

## Configuration

Copy template and edit values:

```bash
cp .env.example .env
```

Main variables:

```env
BOT_TOKEN=...
CHAT_ID=...
AUTH_USERS=root,cloud_2x96c19
CPU_THRESHOLD=90
RAM_THRESHOLD=90
ROOT_FAIL_THRESHOLD=5
ROOT_WINDOW_MINUTES=5
SUCCESS_WINDOW_MINUTES=30
TIMEZONE=UTC+3
STATE_FILE=/var/tmp/tg_monitor_state.env
LOCK_FILE=/var/tmp/tg_monitor.lock
```

`AUTH_USERS` is a comma-separated list. You can change users any time without editing scripts.

## Install

### Safe mode (recommended)

```bash
git clone https://github.com/F0r2yThird/Lightweight-Linux-MonitBash.git tg-monitor
cd tg-monitor
./install.sh
```

### One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/F0r2yThird/Lightweight-Linux-MonitBash/master/install.sh | bash
```

After install:

1. Edit `/opt/tg-monitor/.env`
2. Set `BOT_TOKEN`, `CHAT_ID`, `AUTH_USERS`
3. Test manually:

```bash
ENV_FILE=/opt/tg-monitor/.env /opt/tg-monitor/scripts/monitor.sh
```

## Cron jobs

`install.sh` adds two cron entries (tagged with `# tg-monitor`):

- monitor runner every minute
- bot command polling every minute

## Telegram commands

- `/status` - current values and statuses (`✅` / `🆘`)
- `/thresholds` - configured thresholds
- `/off` - disable alert sending
- `/on` - enable alert sending

## Uninstall

```bash
./uninstall.sh
```

This removes cron entries and deletes `/opt/tg-monitor`.

## Notes

- Data source is `journalctl` first, `/var/log/auth.log` as fallback.
- Time in alerts is formatted using `TIMEZONE` (`UTC+N` / `UTC-N`).
