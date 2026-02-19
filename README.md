# Lightweight Linux Monitoring for AmneziaVPN Host

Минимальный мониторинг для Ubuntu 24 с отправкой алертов в Telegram и очень низкой нагрузкой на сервер (1 GB RAM).

## Что мониторится

- `CPU` (алерт при `> 90%`)
- `RAM` (алерт при `> 90%`)
- Неуспешные попытки входа под `root` за последние 5 минут (алерт при `>= 5`)

Проверка выполняется раз в минуту.

## Поведение алертов

- Тип алерта: `info`
- Антиспам: повтор по той же метрике только после возврата в норму и нового превышения
- Recovery-алерты (о восстановлении) не отправляются

## Управление из Telegram

Поддерживаются команды:

- `/on` - включить отправку алертов
- `/off` - выключить отправку алертов
- `/status` - текущий статус (включен/выключен, последние метрики, пороги)

Важно: включение/выключение реализовано безопасно через флаг в файле состояния, без редактирования `crontab`.

## Структура

- `scripts/monitor.sh` - сбор метрик и отправка алертов
- `scripts/bot_control.sh` - обработка Telegram-команд
- `.env` - конфигурация
- `STATE_FILE` (по умолчанию `/var/tmp/tg_monitor_state.env`) - один перезаписываемый файл состояния

`STATE_FILE` всегда перезаписывается и не растет, поэтому не занимает место на диске со временем.

## Установка

1. Скопировать шаблон:

```bash
cp .env.example .env
```

2. Заполнить `.env`:

```env
BOT_TOKEN=...
CHAT_ID=...
CPU_THRESHOLD=90
RAM_THRESHOLD=90
ROOT_FAIL_THRESHOLD=5
ROOT_WINDOW_MINUTES=5
STATE_FILE=/var/tmp/tg_monitor_state.env
LOCK_FILE=/var/tmp/tg_monitor.lock
```

3. Убедиться, что есть зависимости:

```bash
sudo apt update
sudo apt install -y curl python3
```

4. Дать права на запуск (если нужно):

```bash
chmod +x scripts/monitor.sh scripts/bot_control.sh
```

## Cron (рекомендуется от `root`)

Пример ниже использует каталог `/opt/tg-monitor`. Если у тебя другой путь, замени его в обеих строках.

Открыть cron:

```bash
sudo crontab -e
```

Добавить:

```cron
* * * * * ENV_FILE=/opt/tg-monitor/.env /opt/tg-monitor/scripts/monitor.sh >/dev/null 2>&1
* * * * * ENV_FILE=/opt/tg-monitor/.env /opt/tg-monitor/scripts/bot_control.sh >/dev/null 2>&1
```

## Ручная проверка

```bash
ENV_FILE=/opt/tg-monitor/.env /opt/tg-monitor/scripts/monitor.sh
ENV_FILE=/opt/tg-monitor/.env /opt/tg-monitor/scripts/bot_control.sh
```

Потом отправь боту:

- `/status`
- `/off`
- `/on`

## Примечания

- Для подсчета `Failed password for root` сначала используется `journalctl` за последние 5 минут.
- Если `journalctl` недоступен, используется fallback на `/var/log/auth.log` за то же окно.
- Скрипты используют атомарный lock через `mkdir`, чтобы избежать гонок при одновременном запуске.
