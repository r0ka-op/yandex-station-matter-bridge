# Независимое управление YNDX-00560

Даты аппаратных проверок: 2026-11-09 и финальная проверка независимости 2026-11-10.

## Результат

- **CONFIRMED** — лампа состоит одновременно в Яндекс Fabric (индекс `1` на лампе) и Matter.js Fabric (индекс `2` на лампе).
- **CONFIRMED** — Matter.js Server восстановил commissioned peer с operational Node ID `2` из прежнего `/data`; повторный commissioning не выполнялся.
- **CONFIRMED** — CASE и одиночные Interaction Model Read/Invoke работают через независимую Fabric.
- **CONFIRMED** — после контролируемого перезапуска проверены Off, On, яркость, Hue/Saturation и ColorTemperature с отдельным чтением фактического состояния.
- **CONFIRMED** — автоматический bootstrap Read/subscription данной лампы несовместим с Matter.js 0.18.0: объединённый wildcard-запрос атрибутов и событий завершается `peer-ack-missing` до SubscribeRequest.
- **CONFIRMED** — рабочий production-путь использует официальный `DISABLE_AUTO_SUBSCRIPTION=true`, ограниченный direct invoke внутри единственного Matter.js Server и bounded polling через прямые Read.
- **CONFIRMED** — при физически обесточенной Яндекс Станции прошли CASE, Direct Read, Off/On, brightness, Hue/Saturation, восстановление режима ColorTemperature и polling. После включения Станции Matter.js остался healthy, node доступен, конфликт Fabrics не обнаружен.

`available` в `get_nodes` не считается показателем здоровья подписки. Клиент отдельно сообщает наличие node, значение `available`, успешность direct read и режим `disabled-polling`.

## Обнаруженная структура

Публичный redacted inventory: [YNDX00560_INVENTORY.json](YNDX00560_INVENTORY.json).

| Endpoint | Device/роль | Server clusters |
|---|---|---|
| `0` | Root Node | Descriptor `0x001D`, Access Control `0x001F`, Basic Information `0x0028`, OTA Requestor `0x002A`, General Commissioning `0x0030`, Network Commissioning `0x0031`, Diagnostic Logs `0x0033`, General Diagnostics `0x0034`, Software Diagnostics `0x0036`, Administrator Commissioning `0x003C`, Operational Credentials `0x003E`, Group Key Management `0x003F` |
| `1` | Extended Color Light `0x010D`, rev. 2 | Identify `0x0003`, Groups `0x0004`, OnOff `0x0006`, LevelControl `0x0008`, Descriptor `0x001D`, Scenes `0x0050`, ColorControl `0x0300`, vendor `0x132FFC06`, `0x132FFC0A`, `0x132FFC0C` |

Endpoint `1` имеет клиентский Scenes cluster `0x0050`. Всего обнаружено 22 server clusters.

Подтверждённые команды endpoint `1`:

| Cluster | AcceptedCommandList |
|---|---|
| Identify | `[0,64]` |
| Groups | `[0,1,2,3,4,5]` |
| OnOff | `[0,1,2,64,65,66]` |
| LevelControl | `[0,1,2,3,4,5,6,7]` |
| Scenes | `[0]` |
| ColorControl | `[0,1,2,3,4,5,6,7,8,9,10,71,75,76]` |

ColorControl: FeatureMap=`25`, ColorCapabilities=`25`, физический диапазон `154..370` mired (примерно `6494..2703 K`). На момент свежего snapshot: level `254`, hue `52`, saturation `244`, X/Y `24939/24701`, temperature `154` mired, ColorMode `0`.

Vendor-категория `0x132FFC0C` публикует режимы интерфейса `None`, `Color`,
`Scene`, `Color music`. Селектор штатных сцен оказался стандартным Matter
ModeSelect `0x0050`, command `ChangeToMode(0)`, payload `{newMode:uint8}`.
Аппаратно подтверждены `lava_lamp=1`, `fire=4`, `northern_lights=6` и
`rainbow=13`. Остальные значения общего Quasar enum не вызываются.

`SupportedModes (0x0000)` на проверенной лампе возвращает пустую строку вместо
списка `ModeOptionStruct`, а `CurrentMode (0x0001)` — `0`. Последний выбранный
scene ID хранится в `OnMode (0x0003)`. Поэтому клиент отдельно сообщает
`lastSelectedSceneId` и считает сцену активной только при `OnOff=true` и vendor
category `Scene=2`.

## Исправление Matter.js

Полный interview и bootstrap subscription используют проблемные wildcard/multi-path запросы, поэтому endpoint-модель не строилась, хотя одиночный `node.interaction.read()` проходил. Штатный `device_command` затем завершался локальной ошибкой `Endpoint 1 does not exist` без отправки InvokeRequest.

Образ `yandex-matterjs-server:1.5.5-direct-v1` воспроизводимо строится из pinned base image. Build-time patch сохраняет штатную валидацию схемы, CASE и Interaction Model, но разрешает обход отсутствующей локальной endpoint-модели только для:

- node ID из `YNDX00560_DIRECT_INVOKE_NODE_ID`;
- endpoint `1`;
- OnOff `off/on`;
- LevelControl `moveToLevel`;
- ColorControl `moveToHueAndSaturation` и `moveToColorTemperature`.

Все остальные node/endpoint/cluster/command проходят прежнюю проверку. Произвольного invoke/write интерфейса патч не добавляет. Инструкции сборки и отката: [../../deploy/matter-server-direct/README.md](../../deploy/matter-server-direct/README.md).

Перед развёртыванием создана проверенная резервная копия `/data` вне Git. Compose сохраняет прежние volume, host networking, image version, Fabric identity и credentials.

## Клиент

CLI: `tools/matter_lamp/matter-lamp-client.mjs`.

```powershell
node tools/matter_lamp/matter-lamp-client.mjs get_health
node tools/matter_lamp/matter-lamp-client.mjs get_capabilities
node tools/matter_lamp/matter-lamp-client.mjs get_state
node tools/matter_lamp/matter-lamp-client.mjs turn_off
node tools/matter_lamp/matter-lamp-client.mjs turn_on
node tools/matter_lamp/matter-lamp-client.mjs set_brightness 50
node tools/matter_lamp/matter-lamp-client.mjs set_color 0 100
node tools/matter_lamp/matter-lamp-client.mjs set_color_temperature 4000
node tools/matter_lamp/matter-lamp-client.mjs get_scenes
node tools/matter_lamp/matter-lamp-client.mjs get_scene
node tools/matter_lamp/matter-lamp-client.mjs set_scene rainbow
node tools/matter_lamp/matter-lamp-client.mjs set_scene fire
node tools/matter_lamp/matter-lamp-client.mjs set_scene northern_lights
node tools/matter_lamp/matter-lamp-client.mjs set_scene lava_lamp
```

Яркость задаётся как `1..100%` и преобразуется в Matter level `1..254`. Hue/Saturation задаются в процентах и преобразуются в `0..254`. Цветовая температура проверяется по физическим границам устройства. У всех операций конечный timeout, отсутствуют автоматические повторы, а после Invoke выполняется новый direct Read.

## Аппаратные результаты

| Проверка | Результат | Фактический readback |
|---|---|---|
| Direct Read | PASS | OnOff прочитан с устройства |
| Off | PASS | `false` |
| On | PASS | `true` |
| Brightness 50% | PASS | level `127` после завершения transition |
| Restore brightness | PASS | level `254` |
| Hue/Saturation | PASS | `0/254`, ColorMode `0` |
| Restore Hue/Saturation | PASS | `52/244`, ColorMode `0` |
| ColorTemperature 4000 K | PASS | `250` mired, ColorMode `2` |
| Restore color/temperature | PASS | `154` mired и `52/244`, ColorMode `0` |
| Persistence recovery | PASS | node `2`, прежняя Fabric и CASE после restart |
| Subscription | FAIL | `peer-ack-missing` на bootstrap Read; отключена |
| Fallback polling | PASS | пять последовательных direct Read: `139/69/86/175/31 ms` |

### Финальная проверка независимости — 2026-11-10

Перед отключением Станции сохранён свежий snapshot: OnOff=`true`, level=`254`,
hue/saturation=`52/244`, X/Y=`24939/24701`, temperature=`222` mired,
ColorMode/EnhancedColorMode=`2/2`. Станция была физически обесточена; SSH к ней
завершался timeout, при этом Ubuntu и Wi-Fi оставались доступны.

| Проверка без Станции | Результат | Readback |
|---|---|---|
| CASE/Direct Read | PASS | node present/available, OnOff=`true` |
| Off → On | PASS | `false` → `true` |
| Brightness 50% → restore | PASS | level `127` → `254` |
| Hue/Saturation test | PASS | `38/203`, ColorMode=`0` |
| Restore hue/saturation | PASS | `52/244` |
| Restore color mode/temperature | PASS | `222` mired, ColorMode=`2` |
| Polling | PASS | два последовательных полных snapshot совпали |
| Persistence/node status | PASS | container healthy, restart count `0`, `/data` present |
| Final snapshot | PASS | полностью совпал с исходным snapshot |

После физического включения Станции штатный `platformd` восстановился, TCP/8765
остался закрыт, а CASE/Direct Read Matter.js продолжили работать. Управляющая команда
через Яндекс Fabric отдельно не отправлялась; её сохранность подтверждается ранее
проверенным coexistence и отсутствием признаков конфликта после возврата Станции.

В первичной проверке 2026-11-09 финальный активный state совпал с snapshot:
OnOff=`true`, level=`254`, hue/saturation=`52/244`, X/Y=`24939/24701`,
temperature=`154`, ColorMode=`0`. EnhancedColorMode изменился с исторически
несогласованного `2` при ColorMode=`0` на согласованный `0` после стандартного
переключения режимов; дополнительных слепых команд для возврата этого служебного
значения не отправлялось.

## Следующий этап: Color music (не начат)

Известный контекст для отдельной будущей задачи: vendor cluster `0x132FFC06`,
команды `SetEnable` и `SetAnimation`, vendor category `Color music=3`, а также
UDP/4048 с 120 спектроподобными `uint32 BE` примерно по 49 пакетов/с и
фактическим обновлением около 22 Гц. В текущую реализацию Color music не входит.

## Восстановление

После restart сервер должен использовать тот же `/data`, Fabric identity и operational Node ID `2`. Проверка: container healthy/restart count, `get_health`, затем `get_state`. Новый commissioning не нужен и запрещён. При timeout изменяющей команды её нельзя повторять вслепую: сначала выполнить свежий direct Read и только затем принимать решение о восстановлении.
