# Readiness report

## Актуальное состояние независимого управления — 2026-11-09

Этот раздел заменяет более ранние выводы ниже о `nodes=0`, неподтверждённом commissioning и отсутствии прямого управления.

- **CONFIRMED** — Enhanced Commissioning завершён: DeviceAttestation, AddNOC (`fabricIndex=2` на лампе), CommissioningComplete и CASE прошли; Яндекс Fabric с индексом `1` сохранена.
- **CONFIRMED** — Matter.js восстановил operational node `2` из persistence без нового commissioning.
- **CONFIRMED** — прямые одиночные Read и ограниченные Invoke работают после контролируемого restart: On/Off, level, Hue/Saturation и ColorTemperature подтверждены реальным readback.
- **CONFIRMED** — исходное активное состояние восстановлено. EnhancedColorMode нормализован устройством с несогласованного `2` при ColorMode=`0` на согласованный `0` после стандартной смены режима.
- **CONFIRMED** — автоматический bootstrap Read/subscription Matter.js 0.18.0 несовместим с лампой (`peer-ack-missing` до SubscribeRequest). Используется официальный `DISABLE_AUTO_SUBSCRIPTION=true` и bounded direct polling.
- **CONFIRMED** — узкий build-time patch разрешает direct invoke только для node из env, endpoint `1` и пяти световых команд; произвольный invoke/write не добавлен.
- **NOT EXECUTED** — тест при недоступной Яндекс Станции, поскольку безопасная изоляция потребовала бы отдельного изменения сети.

Подробности, команды, восстановление и аппаратные результаты: [DIRECT_CONTROL.md](DIRECT_CONTROL.md). Публичный inventory: [YNDX00560_INVENTORY.json](YNDX00560_INVENTORY.json).

## Актуализация ECM 2026-11-09

Этот раздел заменяет более ранние оценки `UNKNOWN`/`NO-GO` ниже
в вопросах Timed Invoke и verifier/salt.

- CONFIRMED — generic HTTP `timeout` попадает в
  `Optional<uint16_t> timedInvokeTimeoutMs`; generic binary string — hex bytes.
- CONFIRMED — generic `/interaction/invokeCommand` всё равно NO-GO для ECM:
  JSON command parser не dispatch-ит cluster `0x003C`.
- CONFIRMED — отдельный `POST /commissioning/window` принимает
  `nodeId`, `discriminator`, `timeout`; CHIP SDK сам генерирует PIN,
  32-byte salt, PAKE verifier, ECM TLV и timed invoke.
- CONDITIONAL GO — один separately authorized call этого dedicated route.
- NOT TESTED — real route call, commissioning и вторая Fabric ещё не
  проверены.

Актуальный verdict: [ECM_GO_NO_GO.md](ECM_GO_NO_GO.md); доказательства:
[MAIND_TIMED_INVOKE_ANALYSIS.md](MAIND_TIMED_INVOKE_ANALYSIS.md).

## Аппаратная проверка 2026-11-08

CONFIRMED — выполнен один разрешённый сеанс `MultiAdminReadOnly` с уникальным
`run_id=run-20261108T200458597Z-925c63936a54`. До перезапуска `platformd` прошли
preflight, detached-watchdog self-test и установка IPv4/IPv6 guards. Дедлайн
watchdog составлял 360 секунд. Через HTTP выполнены только `GET /devices` и 11
`readAttribute` для endpoint 0; `invokeCommand` и `writeAttribute` не выполнялись.

CONFIRMED — реальная YNDX-00560 объявляет для Administrator Commissioning
`AcceptedCommandList=[0,1,2]`, то есть `OpenCommissioningWindow`,
`OpenBasicCommissioningWindow` и `RevokeCommissioning`. Остальные результаты:

| Атрибут | Значение |
|---|---:|
| GeneratedCommandList | `[]` |
| AttributeList | `[0,1,2,65528,65529,65531,65532,65533]` |
| FeatureMap | `0` |
| ClusterRevision | `1` |
| WindowStatus | `0` (`WindowNotOpen`) |
| AdminFabricIndex | `null` |
| AdminVendorId | `null` |
| SupportedFabrics | `5` |
| CommissionedFabrics | `1` |
| CurrentFabricIndex | `1` |

CONFIRMED — rollback завершён: штатный `platformd` восстановлен, отдельный
`verify-clean` повторно прошёл. После сеанса отсутствуют listener TCP/8765,
IPv4/IPv6 guards, patch mount/path, global lock и experiment workers. Завершённые
каталоги сохранены; конфиденциальные данные не публикуются.

CONFIRMED — независимый Matter.js Server повторно проверен: контейнер `healthy`,
restart count 0, persistence path существует, HTTP/WS endpoint слушает
`<MATTER_SERVER_LAN_IP>:5580`, mDNS UDP/5353 доступен по IPv4/IPv6. Home Assistant на
стенде не установлен и commissioning не запускался.

INFERRED — устройство на уровне кластера поддерживает Enhanced Commissioning и
имеет четыре свободных fabric slot. Это ещё не доказывает, что `maind` HTTP API
может корректно передать Timed Invoke и binary TLV-поля PAKE verifier/salt.

NO-GO — первая state-changing попытка остаётся запрещённой до отдельного
разрешения и до доказательства корректного Timed Invoke/octet-string encoding.
Production-клиент `ymatter` не изменять и его запрет на cluster `0x003C` не
обходить.

Дата: 2026-11-08

## Итог

Независимый Matter.js Server на `test-stend-server` запущен и проверен без подключения
лампы. Он готов к подключению Home Assistant по
`ws://<MATTER_SERVER_LAN_IP>:5580/ws`. В текущей лаборатории значение параметра проверено
отдельно и не публикуется. Открытие commissioning window, commissioning и любые
изменения fabrics не выполнялись.

| Область | Метка | Результат |
|---|---|---|
| Команды лампы `0x003C` | CONFIRMED | `AcceptedCommandList=[0,1,2]` |
| Fabric capacity лампы | CONFIRMED | SupportedFabrics=5, CommissionedFabrics=1 |
| Enhanced method по стандарту | SOURCE | поддерживаемый стандартный путь Multi-Admin |
| Basic method на лампе | UNKNOWN | command объявлена, но FeatureMap BC=0 |
| `maind` Timed Invoke | UNKNOWN | нет wire evidence корректного Timed Request |
| `maind` octet strings | UNKNOWN | encoding verifier/salt не установлен |
| Matter.js Server | CONFIRMED | healthy, WebSocket API работает, 0 узлов |
| Реальный Multi-Admin YNDX-00560 | NOT TESTED | read-only hardware baseline подтверждён; открытие окна и добавление fabric не выполнялись |

## Фактическое состояние стенда

| Проверка | Метка | Фактический результат |
|---|---|---|
| Ubuntu host | CONFIRMED | `test-stend-server` / `home-server`, Ubuntu 22.04.5 LTS, kernel 5.15.0-202, x86_64 |
| Docker / Compose | CONFIRMED | Docker 29.8.0 (snap), Compose 5.5.1 |
| Ресурсы до запуска | CONFIRMED | 2 CPU, 1.9 GiB RAM, 1.4 GiB available, 2 GiB swap, 420 GiB free |
| Лабораторный интерфейс | CONFIRMED | `enp5s0`, `<MATTER_SERVER_LAN_IP>/24`, IPv6 link-local присутствует |
| IPv6 / multicast | CONFIRMED | IPv6 включён; multicast membership есть; `all.forwarding=0`; kernel имеет `CONFIG_IPV6_ROUTER_PREF` и `CONFIG_IPV6_ROUTE_INFO` |
| Server version | CONFIRMED | `matter-server/1.5.5`, `matter.js/0.18.0`, Matter 1.6.1 |
| Container | CONFIRMED | `healthy`, restart count 0 после контрольного рестарта |
| Web API | CONFIRMED | HTTP `200`; `/ws` дал `101 Switching Protocols`; `get_nodes` вернул 0 узлов |
| Persistence | CONFIRMED | после `docker restart` загружены тот же `server-1-fff1`, controller credentials и DCL cache |
| Сокеты | CONFIRMED | TCP/5580 на loopback, `<MATTER_SERVER_LAN_IP>` и link-local IPv6; UDP/5353 IPv4/IPv6 |
| UDP/5540 | CONFIRMED | свободен при отсутствии peer; закрытый/свободный порт до commissioning не является ошибкой |
| Idle usage | CONFIRMED | около 136 MiB RAM, 0% CPU, 11 процессов |
| Credentials | CONFIRMED | Wi-Fi/Thread credentials не заданы; BLE отключён |

Использованный образ:

```text
ghcr.io/matter-js/matterjs-server@sha256:ee149c7c67eff0e90f131e8f0d628f7b099591ec58473c8cda1209e8ae4df66e
```

## Изменения Ubuntu-хоста

CONFIRMED — выполнены только следующие изменения:

1. Созданы `<LAB_USER_HOME>/matter-lab/compose.yml` и
   `<LAB_USER_HOME>/matter-lab/matter-data` (mode `0700`).
2. Скачан официальный stable image.
3. Создан один непривилегированный контейнер `matterjs-server` с host networking и
   `restart: unless-stopped`.
4. WebSocket ограничен `127.0.0.1,enp5s0`; primary Matter interface — `enp5s0`.

CONFIRMED — firewall, маршруты, NetworkManager, Docker daemon, sysctl и systemd-службы
не менялись. Никакие Matter-устройства не добавлялись.

Первая попытка с `security_opt: no-new-privileges:true` дала
`exec /usr/local/bin/node: operation not permitted`. Изолированный A/B-тест того же
образа подтвердил конфликт этой опции со snap-Docker/AppArmor: с ней Node не запускался,
без неё вернул `v24.22.1`. Опция удалена. Образ продолжает работать как user `1000:1000`.

## Ограничения

- SOURCE — Docker image предназначен для test/evaluation и не считается официально
  поддерживаемой HA-конфигурацией. HA OS остаётся предпочтительным production-вариантом.
- INFERRED — для Wi-Fi YNDX-00560 host networking и IPv6 link-local достаточны, если
  лампа, телефон и `enp5s0` находятся в одной L2-сети.
- UNKNOWN — multicast/mDNS между реальными участниками будет проверен на оборудовании.
- NOT APPLICABLE NOW — NetworkManager 1.36.6, `accept_ra=0` и отсутствие RIO не подходят
  для Thread через внешний Border Router; YNDX-00560 использует Matter over Wi-Fi.
- UNKNOWN — UFW status недоступен без sudo. Не менять firewall без разрешения; сначала
  проверить TCP/5580 с хоста Home Assistant.
- OBSERVED — обновление DCL vendor list один раз завершилось timeout/HTTP 500, но сервер
  использовал встроенный cache (885 vendors, 181 certificates) и остался `healthy`.

## Go/no-go

- `READY`: подключить Home Assistant к WebSocket и выполнить read-only preflight.
- `NO-GO`: открывать окно или запускать commissioning без отдельного разрешения,
  физического присутствия и подтверждения Timed Invoke/octet-string encoding в `maind`.

## Проверка состояния

```bash
cd <LAB_USER_HOME>/matter-lab
docker compose ps
docker inspect matterjs-server --format '{{.State.Health.Status}}'
docker compose logs --no-color --tail=200
ss -lntup | grep -E ':(5353|5540|5580)[[:space:]]'
curl -fsS http://127.0.0.1:5580/ >/dev/null
```

## Первое безопасное действие с оборудованием

Подключить Home Assistant Matter integration к
`ws://<MATTER_SERVER_LAN_IP>:5580/ws`, проверить пустой список узлов и не запускать
**Add device**/discovery. Read-only hardware baseline уже подтверждён; окно не
открывать.

## Источники

- [Official Matter.js Docker guidance](https://github.com/matter-js/matterjs-server/blob/main/docs/docker.md)
- [Matter.js OS/network requirements](https://github.com/matter-js/matterjs-server/blob/main/docs/os_requirements.md)
- [Matter.js WebSocket API](https://github.com/matter-js/matterjs-server/blob/main/docs/websockets_api.md)
- [Home Assistant Matter integration](https://www.home-assistant.io/integrations/matter/)
# Обновление ECM readiness — 2026-11-09

- CONFIRMED — Matter.js Server read-only WebSocket API отвечает как
  `matter-server/1.5.5 (matter.js/0.18.0)`; fabric index 1; `get_nodes=[]`.
- CONFIRMED — установленный server handler имеет `commission_with_code` с
  `network_only=true`; Home Assistant не требуется для добавления узла в fabric сервера.
- CONFIRMED — offline Matter.js SDK правильно кодирует synthetic ECM payload в TLV
  tags 0..4, binary поля как octet strings и выставляет `timed=true`.
- CONFIRMED — static analysis закреплённого `maind` показывает тип
  `OpenCommissioningWindow` в generic HTTP action variant.
- UNKNOWN — HTTP `timeout` не сопоставлен доказательно с Timed Request.
- UNKNOWN — JSON representation для двух `ByteSpan` полей не восстановлен.
- NOT TESTED — реальное открытие окна и commissioning второй fabric.

**Итог: Matter.js Server готов; первый Enhanced Commissioning через `maind` — NO-GO
до закрытия двух UNKNOWN.** Подробности: [ECM_GO_NO_GO.md](ECM_GO_NO_GO.md).
