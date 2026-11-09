# Enhanced Commissioning: GO/NO-GO

Дата: 2026-11-09. Анализ относится к прошивке
`0.369.1.46.4793643989.20261020.299` и бинарнику `maind` SHA-256
`7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1`.

## Решение

- **NO-GO** для `OpenCommissioningWindow` через generic
  `POST /interaction/invokeCommand`.
- **HARDWARE PASS** для одного отдельно разрешённого
  `POST /commissioning/window` после guarded lifecycle preflight.
- **CONFIRMED** — dedicated route открыл окно на реальной Станции;
  PASE, DeviceAttestation, AddNOC и CommissioningComplete прошли, вторая Fabric
  сохранена.

## Почему generic invoke отклонён

CONFIRMED — HTTP handler `0x0118EF9C` разбирает `fields`, затем
вызывает command parser `0x0118F260`. Его начальный dispatch
принимает cluster IDs `3..8`, `0x2A`, `0x30`, `0x31`, `0x3E`, `0x3F`,
`0x50`, `0x101`, `0x300`. Сравнения с `0x3C` нет; ветка уходит в
`UNSUPPORTED_COMMAND`.

CONFIRMED — C++ variant нижнего слоя всё же содержит
`AdministratorCommissioning::OpenCommissioningWindow::Type`. Это не
опровергает барьер: HTTP JSON parser не может создать этот
variant для cluster `0x3C`.

## Timed Invoke

CONFIRMED — поле HTTP JSON `timeout` разбирается функцией
`0x011853C4` как optional 64-bit numeric/string value. После передачи в
`invokeCommandInternal` (`0x01193B20`) оно преобразуется в
`Optional<uint16_t>`; значения `>=65536` принудительно становятся
`65535 ms`. Это совпадает с первым optional-аргументом
CHIP `InvokeCommandRequest`: `timedInvokeTimeoutMs`; response timeout идёт отдельным
`Optional<chrono::milliseconds>`.

CONFIRMED — timed/non-timed режим в generic path выбирается наличием
HTTP `timeout`, а не metadata команды. Автоматического подставления
Timed Invoke для Administrator Commissioning в generic handler нет.

NOT TESTED — generic HTTP timed invoke не проверялся wire capture. Для
ECM это больше не blocker: cluster отсекается раньше.

## JSON → binary

CONFIRMED — converter `0x011914AA` для бинарных полей
поддерживает:

- JSON `null` → пустой byte container;
- JSON string → hex decode, два символа на байт;
- JSON array → поэлементная numeric-to-byte conversion.

CONFIRMED — string не является UTF-8 bytes и не является base64.
Цепочка `0x011914AA → 0x011917A0 → 0x006B1C78` вызывает
hex decoder; нечётная длина даёт `Odd buffer length passed to HexDecode`.

CONFIRMED (offline test) — `007f80FF` декодируется без искажения в
`00 7F 80 FF`; 97-byte verifier и 16-byte salt проходят round-trip.

CONFIRMED — этот converter недостижим для verifier/salt ECM в generic
HTTP API, потому что dispatch не принимает cluster `0x3C`.

## Штатный dedicated route

CONFIRMED — `CommissioningWindowHandler` регистрирует:

- `POST /commissioning/window`;
- `DELETE /commissioning/window/{nodeId}`.

Для первой ECM-попытки DELETE не планируется.

CONFIRMED — POST требует ровно три поля:

```json
{
  "nodeId": 4660,
  "discriminator": 2748,
  "timeout": 300
}
```

Здесь `4660` и `2748` — только synthetic dry-run values. В аппаратном
сеансе подставляются фактический private Node ID и fresh random discriminator.

CONFIRMED — `AdministratorCommissioning::openWindow` валидирует
`nodeId != 0`, discriminator `0..4095`, timeout `180..900 seconds`; поддержан
только enhanced window type.

CONFIRMED — wrapper передаёт в CHIP 1.4
`CommissioningWindowOpener` iterations `1000`, не передаёт setup PIN и salt.
SDK сам:

1. генерирует random setup PIN;
2. генерирует 32-byte salt через DRBG;
3. вызывает `PASESession::GeneratePASEVerifier`;
4. сериализует 97-byte verifier в OpenCommissioningWindow TLV;
5. вызывает command с `MakeOptional(kTimedInvokeTimeoutMs)`;
6. при успехе возвращает `manualCode` и `qrCode`.

INFERRED — это самый простой и наименее ошибкоопасный пут:
не нужно восстанавливать wire-format verifier/salt в HTTP JSON, а криптография
остаётся в штатном CHIP SDK.

## Что остаётся перед GO

1. Новое явное разрешение владельца на один state-changing POST.
2. Отдельный lifecycle mode с allowlist только для exact POST route;
   без generic invoke, DELETE и retries.
3. Повтор baseline: Node ID, `WindowStatus=0`, `CommissionedFabrics=1`,
   Matter.js Server healthy/nodes=0.
4. Генерация fresh discriminator только в оперативной памяти.
5. Немедленная передача returned code в Matter.js
   `commission_with_code`, `network_only=true`; никакого логирования code.
6. После попытки — только rollback Станции и verify-clean. Rollback
   не вызывает RemoveFabric на лампе.

## Источники

- [CHIP CommissioningWindowOpener](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/CommissioningWindowOpener.cpp)
- [CHIP InvokeInteraction](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/InvokeInteraction.h)
- [Administrator Commissioning schema](https://raw.githubusercontent.com/project-chip/connectedhomeip/master/src/app/zap-templates/zcl/data-model/chip/administrator-commissioning-cluster.xml)
- [Matter.js Server WebSocket API](https://github.com/matter-js/matterjs-server/blob/main/docs/websockets_api.md)
- private reproducible evidence: `results/maind_ecm_static_analysis.json`.
