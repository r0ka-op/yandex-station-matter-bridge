# Yandex Station Matter HTTP API and `ymatter`

## Подключение второго Matter-контроллера / Matter Multi-Admin

Яндекс Эмби Лампа YNDX-00560 успешно добавлена в независимую Matter.js Fabric без удаления существующей Яндекс Fabric. Воспроизводимая инструкция описывает защищённое открытие commissioning window, аттестацию, восстановление из persistence, прямое управление и обязательный rollback Станции:

- [Инструкция на русском](docs/multi_admin/HOW_TO_ADD_SECOND_CONTROLLER.md)
- [English guide](docs/multi_admin/HOW_TO_ADD_SECOND_CONTROLLER_EN.md)

Подтверждены Direct Read, On/Off, яркость, Hue/Saturation, ColorTemperature, polling и восстановление после перезапуска. Полная Home Assistant-интеграция и работа при физически отключённой Станции пока не проверены.

## Независимое Matter-управление YNDX-00560

Эмби Лампа YNDX-00560 успешно добавлена во вторую Matter Fabric с сохранением
исходной Яндекс Fabric. Независимый Matter.js Server восстановил узел из
persistence после перезапуска и напрямую выполнил:

- чтение фактического состояния;
- включение и выключение;
- изменение яркости;
- изменение Hue/Saturation;
- изменение цветовой температуры;
- последующий readback и восстановление исходного состояния.

Повторный commissioning для обычной работы не требуется. Production-путь
использует один Matter.js Server и сохранённый `/data`; запуск второго
контроллера с той же Fabric identity не допускается.

Автоматический bootstrap Read/subscription Matter.js 0.18.0 несовместим с этой
версией прошивки лампы и завершается `peer-ack-missing` до SubscribeRequest.
Поэтому auto-subscription отключена штатным параметром сервера, а состояние
получается ограниченными по времени одиночными Read/polling-запросами. Команды
отправляются без автоматических повторов и подтверждаются отдельным readback.

Управление по прямому пути Ubuntu → Matter.js → лампа подтверждено. Тест при
физически или сетево недоступной Яндекс Станции пока **не выполнялся**.

Подробности, ограничения, команды и результаты аппаратных тестов:
[docs/multi_admin/DIRECT_CONTROL.md](docs/multi_admin/DIRECT_CONTROL.md).
Публичный redacted inventory:
[docs/multi_admin/YNDX00560_INVENTORY.json](docs/multi_admin/YNDX00560_INVENTORY.json).

Исследование встроенного Matter HTTP API Яндекс Станции и Python-клиент для работы с уже сопряжёнными Matter-устройствами.

Created and maintained by [r0ka-op](https://github.com/r0ka-op).

Проект не связан с Яндексом. Он не содержит прошивки, OEM-бинарники, Matter credentials или приватные дампы.

## Что обнаружено

В штатном процессе `maind --platformd` Яндекс Станции Мини 2 обнаружен HTTP control plane на TCP/8765. Он позволяет Станции, уже являющейся авторизованным Matter-контроллером, перечислять устройства, читать атрибуты и вызывать команды.

```text
ПК ──SSH exec──> Станция ──wget 127.0.0.1:8765──> maind
                                                     │
                                                     └──Matter/UDP 5540──> устройство
```

API по умолчанию выключен. В проверенной прошивке при включении он слушает `0.0.0.0:8765` и `[::]:8765` без клиентской HTTP-аутентификации. Поэтому его нельзя оставлять доступным из LAN: IPv4- и IPv6-изоляция должны устанавливаться **до** появления listener.

Подробности: [обнаружение](docs/DISCOVERY.md), [HTTP API](docs/API.md), [модель безопасности](docs/SAFETY.md), [совместимость](docs/COMPATIBILITY.md).

## Реальная read-only инвентаризация

7–8 ноября 2026 года выполнен один полный read-only сеанс на Эмби Лампе YNDX-00560:

- 263 API-запроса, 237 успешных чтений;
- 2 endpoint и 22 server-кластера;
- три vendor-кластера Яндекса: `0x132FFC06`, `0x132FFC0A`, `0x132FFC0C`;
- в читаемом списке режимов: `None`, `Color`, `Scene`, `Color music`;
- Color Control объявляет Hue/Saturation, XY и Color Temperature;
- диапазон Color Temperature: 154–370 mired;
- `SupportedFabrics=5`, `CommissionedFabrics=1` — это не доказательство возможности независимого сопряжения;
- lifecycle временной активации, rollback и postflight завершились успешно.

Обезличенная техническая сводка: [docs/REAL_INVENTORY.md](docs/REAL_INVENTORY.md). Vendor-команды в ходе инвентаризации не вызывались.

## Python-клиент `ymatter`

Клиент находится в [`client/`](client/) и предоставляет:

- SSH-exec transport через BusyBox `wget` к loopback API;
- `doctor`, `devices`, `discover`, `state`;
- On/Off, brightness и Hue/Saturation;
- экспериментальную Color Temperature с явным opt-in и проверкой диапазона;
- MQTT bridge и Home Assistant MQTT Discovery;
- TOML-конфигурацию и fail-closed preflight.

Клиент не привязан к конкретному Node ID: световой endpoint выбирается по `/devices` и Descriptor, затем проверяются ServerList, AttributeList и AcceptedCommandList.

### Установка

Требуется Python 3.11 или новее.

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install ./client
```

Для MQTT:

```bash
python -m pip install './client[mqtt]'
```

Создайте локальную конфигурацию вне Git:

```bash
cp client/config.example.toml config.toml
```

Укажите SSH alias Станции и её LAN IPv4. Пароль MQTT передавайте через `YMATTER_MQTT_PASSWORD`, а не сохраняйте в репозитории.

### Первичная проверка

API должен быть уже временно активирован проверенным lifecycle и изолирован firewall. Dropbear на испытанной Станции запрещал SSH `direct-tcpip`, поэтому клиент по умолчанию использует SSH exec, а не `ssh -L`.

```bash
ymatter --config config.toml doctor
ymatter --config config.toml devices
ymatter --config config.toml discover
ymatter --config config.toml state
```

### CLI-управление

Следующие команды меняют физическое состояние устройства. Сначала сохраните baseline и обеспечьте восстановление:

```bash
ymatter --config config.toml on
ymatter --config config.toml off
ymatter --config config.toml brightness 25
ymatter --config config.toml color 210 80
```

Color Temperature отключена по умолчанию. Команда `MoveToColorTemperature` и диапазон объявлены устройством, но вызов через новый Python-клиент на реальном оборудовании ещё не проверялся. Включайте `[lamp].color_temp=true` только для отдельного контролируемого теста.

### MQTT и Home Assistant

После установки extra `mqtt` и настройки секций `[mqtt]`/`[bridge]`:

```bash
ymatter --config config.toml bridge
```

Bridge публикует MQTT Discovery и состояние с readback. Это **offline-tested** поведение; реальная долговременная Home Assistant-интеграция пока не подтверждена.

## Статус проверок

| Возможность | Статус |
|---|---|
| Реальный `maind` API, On/Off, brightness, Hue/Saturation | **CONFIRMED** исследовательскими контроллерами |
| Полная read-only Matter-инвентаризация и rollback | **CONFIRMED** |
| `ymatter` unit/integration tests | **70 PASS**, 4 Unix-shell tests были SKIP на Windows |
| Управление реальной лампой через новый Python-клиент | **NOT TESTED** |
| Color Temperature через `ymatter` | **OFFLINE TESTED / hardware NOT TESTED** |
| Постоянно включённый API | **NOT SUPPORTED / unsafe by default** |
| Реальный Home Assistant bridge | **NOT TESTED** |
| Второй независимый Matter-контроллер | **NOT CONFIRMED** |

Offline-тесты не заменяют аппаратную проверку. План одного ограниченного сеанса: [client/reports/REAL_CLIENT_TEST_PLAN.md](client/reports/REAL_CLIENT_TEST_PLAN.md).

## Исследовательские инструменты

[`scripts/`](scripts/) содержит актуальный lifecycle с:

- уникальным `run_id` и каталогом `/tmp/maind-http-runs/<run_id>`;
- global lock `/tmp/maind-http-runtime.lock`;
- проверкой идентичности бинарников;
- IPv4/IPv6 firewall guards;
- независимым watchdog;
- fail-closed preflight, rollback и `verify-clean`;
- структурированной диагностикой отказов;
- лимитами полной read-only инвентаризации.

Эти скрипты рассчитаны на конкретную исследованную сборку и требуют явных параметров и confirmation tokens. После OTA или на другой модели сначала сравните бинарники, bind/auth model, configuration loader и supervisor behavior. Использование описано в [docs/USAGE.md](docs/USAGE.md).

## Разработка

```bash
python -m pip install -e ./client
python -m compileall -q client/src client/tests
python -m unittest discover -s client/tests -t client -v
ymatter --help
```

Research-тесты и CI не подключаются к реальным устройствам. Подробнее — [RELEASE_NOTES.md](RELEASE_NOTES.md) и [CONTRIBUTING.md](CONTRIBUTING.md).

## Лицензия

Apache-2.0, см. [LICENSE](LICENSE) и [NOTICE](NOTICE).
