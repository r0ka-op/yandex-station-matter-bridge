# Matter Multi-Admin: commissioning methods

## Подтверждённая база

CONFIRMED — YNDX-00560 объявляет Administrator Commissioning commands
`[0,1,2]`: `OpenCommissioningWindow`, `OpenBasicCommissioningWindow`,
`RevokeCommissioning`. `SupportedFabrics=5`, `CommissionedFabrics=1`,
`CurrentFabricIndex=1`, `WindowStatus=0`.

SOURCE — все три команды требуют privilege `Administer` и Timed
Invoke. Это не HTTP response timeout: Matter controller сначала
отправляет `TimedRequest`, получает SUCCESS и затем посылает
`InvokeRequest` с timed flag.

## Enhanced Commissioning Method

SOURCE — `OpenCommissioningWindow` command `0x00` на endpoint 0 содержит:

| Context tag | Поле | Тип/ограничение |
|---:|---|---|
| 0 | `commissioningTimeout` | uint16 seconds |
| 1 | `PAKEPasscodeVerifier` | octet string, 97 bytes |
| 2 | `discriminator` | uint16, long discriminator `0..4095` |
| 3 | `iterations` | uint32, `1000..100000` |
| 4 | `salt` | octet string, `16..32` bytes |

SOURCE — setup PIN, salt и verifier должны быть согласованы:
controller создаёт verifier через Matter SDK/SPAKE2+, а второй controller
использует pairing code с тем же setup PIN и discriminator.

CONFIRMED — Matter.js 0.18.0 offline формирует context tags
`[0,1,2,3,4]`, кодирует verifier/salt как TLV octet strings и помечает
command `timed=true`.

## Basic Commissioning Method

SOURCE — `OpenBasicCommissioningWindow` command `0x01` передаёт только
`commissioningTimeout`. Он открывает окно с original setup code
и считается менее предпочтительным для Multi-Admin.

UNKNOWN — хотя лампа объявляет command 1, наличие и доступность
её original setup code не подтверждены. Первый опыт должен быть ECM.

## Фактические HTTP пути `maind`

### Generic invoke: NO-GO для ECM

CONFIRMED — `POST /interaction/invokeCommand` в общем случае умеет
Matter Timed Invoke: JSON `timeout` становится
`Optional<uint16_t> timedInvokeTimeoutMs`, предел `65535 ms`.
Без поля `timeout` timed mode не выбирается автоматически.

CONFIRMED — binary converter для поддержанных typed commands
принимает hex string и byte array. Строка — hex, не UTF-8/base64.

CONFIRMED — начальный JSON command parser не имеет branch для
cluster `0x003C`. Он возвращает `UNSUPPORTED_COMMAND` до binary
conversion и connector. Поэтому generic invoke нельзя использовать для
ECM, несмотря на наличие OpenCommissioningWindow type в lower-level
C++ variant.

### Dedicated route: основной путь

CONFIRMED — `POST /commissioning/window` требует:

```json
{
  "nodeId": 4660,
  "discriminator": 2748,
  "timeout": 300
}
```

Значения выше synthetic. В сеансе: фактический private Node ID,
fresh CSPRNG discriminator, timeout `180..900` seconds.

CONFIRMED — route поддерживает только enhanced type и вызывает
CHIP 1.4 `CommissioningWindowOpener` с iterations `1000`, без заданных
setup PIN/salt. SDK сам:

1. генерирует random setup PIN;
2. генерирует 32-byte salt через DRBG;
3. вызывает `PASESession::GeneratePASEVerifier`;
4. формирует ECM TLV и timed invoke;
5. возвращает `manualCode`/`qrCode` при успехе.

INFERRED — dedicated route минимизирует риск ошибки: verifier/salt
не проходят через JSON, криптография остаётся в штатном SDK.

NOT TESTED — route не вызывался на реальной Станции.

## Matter.js Server

CONFIRMED — server `1.5.5` / matter.js `0.18.0` healthy, persistence
проверена, controller nodes=`0`, WebSocket API отвечает.

CONFIRMED — `commission_with_code` принимает returned pairing code.
Для уже находящейся в Wi-Fi лампы выбран
`network_only=true`; Home Assistant на этом шаге не нужен.

```json
{
  "message_id": "explicit-authorized-commission",
  "command": "commission_with_code",
  "args": {
    "code": "<IN_MEMORY_TEMPORARY_CODE>",
    "network_only": true,
    "discovery_timeout_s": 300
  }
}
```

## Закрытие окна и ошибки

SOURCE — окно закроется по timeout или после успешного PASE.
`RevokeCommissioning`/DELETE тоже штатные, но любое их применение
требует отдельного разрешения. По умолчанию при ошибке ждать
timeout, не делать retry.

Возможные отказы: AccessDenied, UnsupportedCommand, Busy/window already
open, invalid config, CASE/session failure, mDNS/discovery timeout, PASE error,
fabric table/ACL limits. Ни один из них не оправдывает automatic
retry, RemoveFabric или factory reset.

## Источники

- [Administrator Commissioning schema](https://raw.githubusercontent.com/project-chip/connectedhomeip/master/src/app/zap-templates/zcl/data-model/chip/administrator-commissioning-cluster.xml)
- [CHIP CommissioningWindowOpener](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/CommissioningWindowOpener.cpp)
- [CHIP InvokeInteraction](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/InvokeInteraction.h)
- [Matter.js Server WebSocket API](https://github.com/matter-js/matterjs-server/blob/main/docs/websockets_api.md)
- [Технический разбор `maind`](MAIND_TIMED_INVOKE_ANALYSIS.md)
