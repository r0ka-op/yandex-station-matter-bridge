# Home Assistant Matter setup

## Выбранный вариант и статус

Production-стенд использует patched Matter.js Server 1.5.5 / matter.js 0.18.0 из
[`deploy/matter-server-direct`](../../deploy/matter-server-direct/README.md) на Ubuntu с
host networking. Он сохраняет существующую Fabric в `/data` и доступен по
`ws://<MATTER_SERVER_LAN_IP>:5580/ws`.

- **CONFIRMED** — CASE, Direct Read/Invoke, polling и восстановление после restart.
- **CONFIRMED** — bootstrap Read/subscription завершается `peer-ack-missing` до
  SubscribeRequest на проверенной прошивке лампы.
- **CONFIRMED** — production fallback использует `DISABLE_AUTO_SUBSCRIPTION=true` и
  bounded Direct Read/polling.
- **NOT TESTED** — полноценная Home Assistant Matter integration с этим patched server.
- **NOT TESTED** — Home Assistant как отдельная дополнительная Fabric.

Официальный проект предоставляет Docker image для test/evaluation, но custom container
не является поддерживаемой конфигурацией Home Assistant. Для стандартной постоянной
установки предпочтителен Home Assistant OS с official Matter Server app. Windows Docker
Desktop не выбран из-за VM/NAT и менее предсказуемой IPv6 link-local/mDNS semantics.

## Фактическая конфигурация

Файл: `deploy/matter-server/docker-compose.ubuntu.yml`.

```yaml
services:
  matter-server:
    image: yandex-matterjs-server:1.5.5-direct-v1
    container_name: matterjs-server
    restart: unless-stopped
    network_mode: host
    environment:
      STORAGE_PATH: /data
      PRIMARY_INTERFACE: <LINUX_LAN_INTERFACE>
      ENABLE_TEST_NET_DCL: "true"
      DISABLE_AUTO_SUBSCRIPTION: "true"
      YNDX00560_DIRECT_INVOKE_NODE_ID: "<OPERATIONAL_NODE_ID>"
      LISTEN_ADDRESS: 127.0.0.1,<LINUX_LAN_INTERFACE>
      LOG_LEVEL: info
      MATTER_LOG_FORMAT: plain
    volumes:
      - <MATTER_DATA_DIR>:/data
```

Угловые скобки — placeholders: этот YAML нельзя запускать буквально. В приватной копии
замените interface, operational Node ID и путь к постоянному storage. Исходный
[`docker-compose.ubuntu.yml`](../../deploy/matter-server/docker-compose.ubuntu.yml)
содержит параметры лаборатории и тоже требует адаптации.

`ENABLE_TEST_NET_DCL=true` включает штатное доверие к Test DCL для test/development PAA,
а не отключает attestation. `YNDX00560_DIRECT_INVOKE_NODE_ID` — fail-closed allowlist:
не подставляйте демонстрационный ID, если фактический operational Node ID неизвестен.

Развёрнутая копия находится в `<LAB_USER_HOME>/matter-lab`. Управление:

```bash
cd <LAB_USER_HOME>/matter-lab
docker compose ps
docker compose logs --no-color --tail=200
docker compose up -d
docker compose stop
```

Не выполнять `down -v` и не удалять `matter-data`: там хранится fabric независимого
контроллера.

## Проверенный результат

- CONFIRMED — `matter-server/1.5.5`, `matter.js/0.18.0`, container healthy.
- CONFIRMED — HTTP dashboard дал `200`.
- CONFIRMED — `ws://127.0.0.1:5580/ws` дал `101 Switching Protocols` и `server_info`.
- CONFIRMED — после commissioning и recovery WebSocket `get_nodes` возвращает узел.
- CONFIRMED — после restart загружены прежний server identity и controller credentials.
- CONFIRMED — Wi-Fi/Thread credentials не заданы; BLE отключён.
- CONFIRMED — direct-control patch разрешает только настроенный Node ID, endpoint 1 и
  OnOff `on/off`, LevelControl `moveToLevel`, ColorControl
  `moveToHueAndSaturation`/`moveToColorTemperature`.
- NOT TESTED — доступ и управление с фактического Home Assistant host/Companion App.

## Subscription и polling fallback

Matter.js 0.18.0 выполняет объединённый bootstrap Read атрибутов и событий до
SubscribeRequest. YNDX-00560 не завершает этот обмен. Это не потеря CASE или Fabric:
малые Direct Read и Invoke работают.

Production-путь использует отключённую auto-subscription, небольшие bounded Direct Read,
последующий readback и периодический polling без бесконечных retry loops. Patch не
разрешает raw write, Fabric/ACL/commissioning или vendor-specific invoke.

```bash
node tools/matter_lamp/matter-lamp-client.mjs --uri ws://<MATTER_SERVER_LAN_IP>:5580/ws --node <OPERATIONAL_NODE_ID> get_health
node tools/matter_lamp/matter-lamp-client.mjs --uri ws://<MATTER_SERVER_LAN_IP>:5580/ws --node <OPERATIONAL_NODE_ID> get_state
```

## Подключение Home Assistant

Подключение server не является commissioning и может быть выполнено заранее:

1. Обновить Home Assistant и Companion App до актуальных версий.
2. В Home Assistant открыть **Settings → Devices & services → Add integration → Matter**.
3. На экране **Select the connection method** снять флажок автоматической установки
   official Matter Server app.
4. Нажать Submit и ввести `ws://<MATTER_SERVER_LAN_IP>:5580/ws`.
5. Убедиться, что integration загружена и использует прежний `/data`/Fabric identity.
6. Не считать появление устройства гарантированным: из-за неполного interview стандартный
   `device_command` может вернуть `Endpoint 1 does not exist`.
7. Не нажимать Add device до отдельного разрешения на commissioning.

Если HA работает на том же Ubuntu host с host networking, допустим
`ws://127.0.0.1:5580/ws`. С другого хоста нужен LAN URL выше.

## Companion App для будущего Multi-Admin

Подготовка без запуска commissioning:

1. Android: полная версия Companion из Play Store, Android 8.1+ (рекомендуется 12+),
   актуальные Google Play Services, Bluetooth включён, Location = Allow all the time.
   Проверить **Android Settings → Google → Devices & sharing → Matter devices**.
2. iOS: iOS 16+ и актуальная Companion App; Bluetooth включён.
3. Телефон подключить к основной 2.4 GHz LAN TP-Link, без guest/client isolation.
4. После отдельного разрешения и фактического открытия window:
   **HA Companion → Settings → Connectivity → Matter → Add device → Yes, it’s already
   in use**.
5. SOURCE — официальный UI предлагает выбрать текущую ecosystem для известных platforms.
   UNKNOWN — Яндекс может отсутствовать в этом списке. В таком случае использовать
   ручной ввод временного commission code/QR, полученного при Enhanced window, если UI
   его предлагает. Не использовать заводской код как замену временному ECM code.
6. Для уже работающей по Wi-Fi лампы Matter.js поддерживает network-only commissioning.
   Ubuntu BLE не требуется; телефонный platform flow всё равно может требовать Bluetooth.

Для первоначального подтверждённого добавления второй Fabric Yandex controller должен
безопасно открыть окно и выдать временный code. Уже подключённый Matter.js Server 1.5.5
имеет `open_commissioning_window`, но этот путь на YNDX-00560 **NOT TESTED**.

## Сетевые требования

- Ubuntu `<LINUX_LAN_INTERFACE>`, лампа, Станция, HA и телефон — одна L2 LAN/VLAN.
- IPv6 link-local и multicast должны проходить; Internet IPv6 и DHCPv6 не обязательны.
- mDNS/DNS-SD multicast не должен фильтроваться или ломаться reflector'ом.
- TCP/5580 нужен от HA до Matter Server; не публиковать его в Internet.
- Matter operational port рекламируется устройством и не обязан заранее быть UDP/5540.
- Не менять firewall/маршруты до диагностики конкретного отказа.

## HA OS как альтернатива

Для постоянного стенда использовать HA OS 10+ на отдельном устройстве либо VM с bridged
Ethernet NIC в ту же LAN. Не использовать NAT-only virtual network. Bridging физического
Ethernet предсказуемее Wi-Fi client bridge. В HA OS Matter integration автоматически
устанавливает и сопровождает official Matter Server app.

## Источники

- [Home Assistant Matter integration and Companion flows](https://www.home-assistant.io/integrations/matter/)
- [Official Matter.js Docker guidance](https://github.com/matter-js/matterjs-server/blob/main/docs/docker.md)
- [Matter.js OS/network requirements](https://github.com/matter-js/matterjs-server/blob/main/docs/os_requirements.md)
- [Matter.js WebSocket API](https://github.com/matter-js/matterjs-server/blob/main/docs/websockets_api.md)
