# `maind`: Timed Invoke и binary fields

Офлайн-анализ бинарника `maind` SHA-256
`7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1`.
Бинарник не запускался; Станция и лампа не опрашивались.

## Generic `/interaction/invokeCommand`

```text
HTTP handler 0x0118EF9C
  fields -> command parser 0x0118F260
  timeout -> optional-number parser 0x011853C4
  typed action -> invokeCommandInternal 0x01193B20
  connector -> CHIP InvokeCommandRequest
```

CONFIRMED — command parser принимает cluster IDs `3..8`, `0x2A`,
`0x30`, `0x31`, `0x3E`, `0x3F`, `0x50`, `0x101`, `0x300`. Для `0x3C`
сравнения/ветки нет, поэтому HTTP request завершается
`UNSUPPORTED_COMMAND` до создания typed ECM command.

CONFIRMED — `OpenCommissioningWindow::Type` в compiled C++ variant есть, но
он недостижим из HTTP JSON из-за dispatch выше.

## HTTP `timeout`

CONFIRMED — `0x011853C4` ищет JSON key `timeout`, принимает
numeric или numeric string, разбирает uint64 и выставляет optional flag.

CONFIRMED — `0x01193B20` сужает это значение до
`Optional<uint16_t>`; при `timeout >= 65536` логирует
`Timeout is too much, setting to 65535ms` и ставит `65535`.

CONFIRMED — внутренняя CHIP signature содержит после request
два разных optional-аргумента: `Optional<uint16_t>` и
`Optional<chrono::milliseconds>`. В официальном CHIP API это
`timedInvokeTimeoutMs` и `responseTimeout`. Следовательно, HTTP
`timeout` — Matter timed timeout, а не HTTP/response timeout.

CONFIRMED — timed/non-timed выбор зависит от наличия JSON `timeout`.
Metadata `mustUseTimedInvoke` не подставляет его автоматически.

NOT TESTED — wire exchange для generic HTTP timed command не выполнялся.

## JSON binary conversion

CONFIRMED — `0x011914AA` обрабатывает binary JSON value:

- `null` → empty byte container;
- string → `0x011917A0` → hex decoder `0x006B1C78`;
- array → per-element numeric conversion в `0x011915DE`.

CONFIRMED — string кодируется hex-парами, не UTF-8 и не base64.
Нечётная длина вызывает `Odd buffer length passed to HexDecode`.
Явного generic maximum length в converter не обнаружено; длину дополнительно
ограничивает typed command schema.

CONFIRMED (offline) — `007f80FF` декодируется в `00 7F 80 FF`;
97-byte и 16-byte synthetic values проходят exact round-trip.

CONFIRMED — для ECM этот converter недостижим: cluster `0x3C`
отклоняется раньше.

## Dedicated commissioning handler

```text
0x01181BC0: POST /commissioning/window
0x01181DE0: require nodeId, discriminator, timeout
             -> IAdministratorCommissioning::openWindow(WindowConfig)
0x012205E8: nodeId != 0, discriminator 0..4095, timeout 180..900
             -> enhanced window only
0x01220B9C: iterations=1000, setupPIN=null, salt=null
             -> CHIP 1.4 CommissioningWindowOpener 0x01221C40
```

CONFIRMED — CHIP opener генерирует random setup PIN и 32-byte salt
через DRBG, вызывает `PASESession::GeneratePASEVerifier`, сериализует
verifier и вызывает `OpenCommissioningWindow` с
`MakeOptional(kTimedInvokeTimeoutMs)`. При успехе HTTP response содержит
`manualCode` и `qrCode`.

| Вопрос | Generic invoke | Dedicated route |
|---|---|---|
| Matter Timed Invoke | CONFIRMED при JSON `timeout` | CONFIRMED: SDK timed timeout |
| Binary verifier/salt | Converter CONFIRMED, но для ECM недостижим | Генерируются SDK, в JSON не передаются |
| ECM | NO-GO | CONDITIONAL GO; NOT TESTED on hardware |

## Альтернативы

- CONFIRMED — dedicated route уже является штатным adapter к Matter
  controller; другой IPC не нужен.
- UNKNOWN — публичный UI/API Яндекса, вызывающий этот route для
  YNDX-00560, не найден.
- NO-GO — binary patch, injection, извлечение Fabric credentials и
  самописная SPAKE2+ не нужны и не допускаются.

## Воспроизводимость

```powershell
python scripts/analyze_maind_ecm.py
python -m unittest tests/test_ecm_open_window.py tests/test_maind_ecm_offline.py
python tools/maind_commissioning_window.py --node-id 0x1234 --discriminator 0xABC --timeout 300
```

Public helpers не содержат HTTP transport и не генерируют credentials.

## Источники

- [CHIP CommissioningWindowOpener](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/CommissioningWindowOpener.cpp)
- [CHIP InvokeInteraction](https://github.com/project-chip/connectedhomeip/blob/master/src/controller/InvokeInteraction.h)
- [CHIP CommandSender](https://github.com/project-chip/connectedhomeip/blob/master/src/app/CommandSender.h)
- [Administrator Commissioning schema](https://raw.githubusercontent.com/project-chip/connectedhomeip/master/src/app/zap-templates/zcl/data-model/chip/administrator-commissioning-cluster.xml)
