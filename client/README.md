# ymatter-bridge

## Real-inventory status (2026-11-08)

The client now consumes Descriptor, AttributeList, AcceptedCommandList and
FeatureMap before selecting a light endpoint or issuing a command. The real
YNDX-00560 inventory declared an Extended Color Light endpoint with OnOff,
LevelControl and ColorControl. It is not bound to the observed Node ID: automatic
selection uses the device list and Descriptor data, while an explicit target is
still validated.

Color temperature was declared with MoveToColorTemperature (`0x0A`) and physical
bounds 154..370 mired (safe integer UI range 2703..6493 K). The request fields
match the Matter model: `colorTemperatureMireds`, `transitionTime`, `optionsMask`
and `optionsOverride`. Because command `0x0A` has not yet been exercised on the
real lamp through this client, it remains disabled unless `[lamp].color_temp=true`;
capability and physical-range checks still apply after opt-in.

BusyBox `wget` transport now preserves real HTTP status codes. An HTTP 500 from
maind is reported as an HTTP/protocol error rather than as loss of SSH or TCP.
Only `UNSUPPORTED_ATTRIBUTE` is treated as an optional missing attribute; access
and other Matter errors remain fatal. The sanitized real-inventory fixture used by
tests contains no original node ID, MAC, serial, network identifiers, fabric IDs,
certificates or keys.

Небольшой CLI и MQTT-мост для управления **Эмби Лампой YNDX-00560** через
встроенный Matter HTTP API рутованной Яндекс Станции. Исследование API:
[r0ka-op](https://github.com/r0ka-op), проект
[yandex-station-matter-bridge](https://github.com/r0ka-op/yandex-station-matter-bridge).
Неофициальный проект, не связан с Яндексом.

**Статус: экспериментальный.** После ревью исправлены ошибки клиента и
подготовлены offline-тесты. На реальных Станции/лампе **этот выпуск не испытан**;
40 первоначальных тестов расширены регрессионными проверками. Постоянный режим
Matter HTTP API **не реализован**.

## Архитектура

```text
ПК / сервер / Raspberry Pi
  ├── ymatter CLI
  └── ymatter bridge ──MQTT──▶ Home Assistant
           │
           └── SSH exec ──▶ wget http://127.0.0.1:8765 на Станции
                                              │
                                штатный Matter-контроллер maind
                                              │
                                         Эмби Лампа
```

SSH-туннель `ssh -L` **не работает** на проверенной Мини 2: Dropbear отказывает
в TCP forwarding (`administratively prohibited`). Поэтому по умолчанию выбран
`ssh-exec` (удалённый BusyBox `wget`), но его работа именно с этой сборкой wget
**ещё не проверена**. `tunnel` оставлен только для других SSH-серверов с forwarding.

## Возможности

- `doctor` — read-only проверки SSH, IPv4/IPv6 firewall guards, известных хешей
  `maind`/`quasar_launcher2`, проверки TCP/8765 **с компьютера клиента**.
- `devices`, `state`, `discover` — чтение устройств и атрибутов.
- `on`, `off`, `brightness`, `color` — allowlist Matter-команд, readback с повторами.
- `temp` — **опциональный эксперимент**; реальная форма `colorTemperatureMireds`
  для этой лампы ещё не проверена. По умолчанию отключён.
- `bridge` — MQTT Discovery light для Home Assistant, с availability/состоянием.

Клиент не содержит `/interaction/writeAttribute`, произвольных команд или
управления фирменными кластерами. Ответ считается успешным только при
подтверждённом `responses`/identity/Success; итог проверяется readback.

Яркость `0%` в CLI и `brightness: 0` в MQTT означает **выключение**, а не
`On` + `MoveToLevel(1)`.

## Установка (на ПК, без изменения Станции)

Нужны Python 3.11+, OpenSSH, SSH-доступ с ключом и заранее настроенный API.
Для MQTT нужен пакет `paho-mqtt>=2.0` и доступный брокер.

```bash
python -m venv .venv
. .venv/bin/activate
pip install -e '.[mqtt]'
cp config.example.toml config.toml
# В config.toml задайте ssh_alias и IPv4 Станции.
ymatter doctor
```

В PowerShell активация окружения: `.\.venv\Scripts\Activate.ps1`, копирование
файла: `Copy-Item config.example.toml config.toml`.

`config.toml` в Git исключён. Пароль MQTT лучше передавать через
`YMATTER_MQTT_PASSWORD`; проверьте защиту своего брокера.

## Как работать с guard и API

ВНИМАНИЕ: этот пакет **не включает** HTTP API, не меняет Quasar и не даёт
готового безопасного постоянного режима. API необходимо активировать отдельно,
через актуальные инструменты исследования, со своим watchdog и rollback.
Не используйте старый lifecycle с общим `/tmp/maind-http-test`.

`station/guard.sh` — вспомогательный скрипт. Его нельзя считать доказательством
сетевой изоляции. Перед использованием изучите [SECURITY.md](SECURITY.md).
Если передаёте его на Dropbear, обычный `scp` может использовать неподдерживаемый
SFTP. Альтернативный способ передачи файла через SSH (под своей ответственностью):

```bash
ssh station-root 'mkdir -p /data/opt/ymatter && cat > /data/opt/ymatter/guard.sh' < station/guard.sh
ssh station-root 'sh /data/opt/ymatter/guard.sh status'
```

Команда `install` **меняет firewall Станции**. Не запускайте её и не активируйте
API без собственного проверенного плана отката. Правильный общий порядок:
сначала изолировать HTTP API, затем включить, после завершения выключить API
и только тогда снимать guard.

Когда API безопасно включён, сначала выполните **только чтение**:

```bash
ymatter doctor
ymatter devices
ymatter discover
ymatter state
```

Если `doctor` показывает **FAIL**, остальные команды выполнять нельзя.
Необязательная проверка IPv6-адреса без его указания помечается предупреждением;
это не означает, что IPv6-проверка выполнена.

После отдельной проверки реального формата HTTP и полученного разрешения на
изменяющие команды можно использовать:

```bash
ymatter on
ymatter brightness 40
ymatter color 120 100
ymatter off
```

## MQTT и Home Assistant

```bash
ymatter bridge
```

Мост работает **только с уже включённым API**. Для старта и выбора endpoint
API должен быть доступен. После завершения временного сеанса мост покажет
`unavailable`, а при возвращении API восстановит работу, если контроллер ещё
работает. Никакая команда не активирует API самостоятельно.

При работе мост периодически повторяет read-only проверки защиты (по умолчанию
30 секунд), а **перед каждой изменяющей командой — всегда**. При отказе команды
блокируются, availability становится `offline`. Retained MQTT-команды игнорируются.
Это снижает риски, но **не исключает гонку** между проверкой и действием. MQTT
с реальным брокером и Home Assistant пока не тестировался.

## Безопасность и ограничения

- Сервер `maind:8765` без аутентификации, может слушать `0.0.0.0` и `::`.
- Preflight не проверяет порядок всех firewall-правил и все подсети LAN.
- Хеши бинарников имеют статус **known-for-tested-build**, не означают
  автоматически безопасную работу после OTA. Неизвестный хеш — FAIL по умолчанию.
- Вариант `--skip-preflight` разрешён **только** с `transport=direct` и loopback
  для локальных тестов; по SSH обход проверок отключён.
- На Станции/лампе пакет не проверен. Нет долговременной изоляции и автозапуска.
- При ошибке на железе **не повторяйте активирующие эксперименты автоматически**.

## Тесты

```bash
python -m unittest discover -s tests -t .
python -m compileall -q src tests
busybox sh -n station/guard.sh    # если установлен BusyBox
```

В CI также предусмотрен ShellCheck. Offline-тесты, в том числе имитация
iptables/ssh/API, **не заменяют реальное испытание**. Сведения о безопасности:
[SECURITY.md](SECURITY.md). Изменения: [CHANGELOG.md](CHANGELOG.md).

## Лицензия

Apache-2.0, см. [LICENSE](LICENSE). Краткая информация о проекте и авторстве —
[NOTICE](NOTICE). Перед публикацией изменений и отправкой материалов из вашего
устройства проверьте, что они не содержат конфиденциальных данных.
