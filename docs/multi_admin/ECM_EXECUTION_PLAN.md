# План одного аппаратного эксперимента Multi-Admin ECM

Дата подготовки: 2026-11-09. Этот документ описывает будущий сеанс; ни одна
изменяющая команда при подготовке не выполнялась.

## Решение

- **CONFIRMED** — лампа объявила команды Administrator Commissioning `[0,1,2]`,
  `SupportedFabrics=5`, `CommissionedFabrics=1`, `WindowStatus=0`.
- **CONFIRMED** — в исследованной версии `maind` есть штатный
  `POST /commissioning/window`, использующий CHIP `CommissioningWindowOpener` и
  возвращающий `manualCode`/`qrCode`.
- **NOT TESTED** — dedicated route ещё не вызывался на реальном устройстве.
- **INFERRED** — эксперимент имеет **условный GO** только как один явно
  разрешённый вызов по приведённому lifecycle. Повтор POST, fallback через
  generic invoke и автоматическое закрытие окна запрещены.

## Реализованный режим `MultiAdminECM`

Точка входа: `scripts/start_maind_http_multi_admin_ecm.ps1`.

Режим повторно использует неизменённый station-side helper: preflight, IPv4 и
IPv6 guards до listener, независимый watchdog, уникальный `run_id`, global lock,
rollback и `verify-clean`. Добавлена только controller-side allowlist:

1. `GET /devices`;
2. `POST /interaction/readAttribute` только для endpoint 0 и пар
   `60/65529`, `60/0`, `62/2`, `62/3`, `62/5`;
3. ровно один `POST /commissioning/window` с полями `nodeId`, `discriminator`,
   `timeout`.

`invokeCommand`, `writeAttribute`, `DELETE`, неизвестные маршруты, лишние JSON-
поля и чужой Node ID отклоняются до транспорта. Node ID извлекается из свежего
`/devices` и должен совпасть с обязательным ожидаемым ID. `4660` запрещён как
демонстрационное значение.

One-shot marker записывается **до** HTTP-транспорта. Поэтому HTTP timeout, SSH
loss, 404, 500 и неполный ответ оставляют POST использованным: автоматического
повтора в этом run нет.

## Работа с кодом подключения

`manualCode` и `qrCode` принимаются только в памяти controller process. В файл
попадают лишь признаки наличия и длины. Затем `manualCode` напрямую включается
в WebSocket-команду Matter.js:

```json
{
  "message_id": "<ephemeral-id>",
  "command": "commission_with_code",
  "args": {
    "code": "<in-memory-only>",
    "network_only": true,
    "discovery_timeout_s": 300
  }
}
```

**CONFIRMED (offline)** — тест редактирования не допускает попадания синтетических
manual/QR code, `salt` и `verifier` в redacted summary и diagnostic text.

**OPERATIONAL REQUIREMENT** — реальный запуск нельзя выполнять под
`Start-Transcript`, с shell tracing или захватом stdout всего процесса. Сценарий
сам не печатает secret response, но не может надёжно выключить внешний
родительский recorder.

## Тайминги

| Ограничение | Значение | Обоснование |
|---|---:|---|
| commissioning window | 600 s | допустимо обработчиком `maind` (180–900 s), оставляет запас после discovery |
| HTTP POST transport | 60 s; controller 75 s | route должен подтвердить открытие, а не ждать окончания окна |
| Matter.js discovery | 300 s | меньше окна на 300 s |
| ожидание результата Matter.js | discovery + 60 s | ограничивает WebSocket operation без retry |
| station watchdog | 1500 s | absolute independent ceiling; controller stops main work at 1140 s |
| read-only reconciliation | 20–30 s/read | только после one-shot boundary |

Проверки параметров запрещают окно короче `discovery + 120 s` и watchdog короче
`discovery + 300 s`. Watchdog — аварийная граница, не штатный таймер завершения.

## Точная последовательность разрешённого будущего сеанса

1. Пассивно проверить SSH, фактические адреса, firmware/SHA, отсутствие TCP/8765,
   незавершённых runs, lock, mounts и patch; Matter.js healthy/persistence/WS,
   `get_nodes=[]`.
2. Зафиксировать ожидаемый Node ID из последнего read-only результата, но после
   активации обязательно заново получить `/devices` и сверить ID и endpoints
   `0,1`. Любое расхождение — rollback без POST.
3. Получить отдельное разрешение именно на один ECM run и запустить entry point
   с точными SSH/IP/Node/WS параметрами. Не использовать PowerShell transcript.
4. Lifecycle выполнит preflight, self-test watchdog, guards, временную активацию,
   затем проверит недоступность TCP/8765 по фактическим LAN IPv4 и IPv6.
5. Выполнить пять baseline reads. Требовать `[0,1,2]`, `WindowStatus=0`,
   `CommissionedFabrics=1`; сохранить `SupportedFabrics` и
   `CurrentFabricIndex`.
6. Создать ephemeral discriminator через OS CSPRNG (или передать заранее
   проверенный), записать one-shot claim и выполнить единственный dedicated
   POST с `timeout=600`.
7. Проверить структуру ответа только в памяти и read-only `WindowStatus != 0`.
   404/500/timeout/неполный ответ — никаких fallback или повторов.
8. Немедленно передать `manualCode` в Matter.js `commission_with_code` с
   `network_only=true`, `discovery_timeout_s=300`; ожидать один результат.
9. Read-only проверить `CommissionedFabrics=2`, `WindowStatus` и Matter.js node
   list. Несогласованный результат классифицировать как ambiguous; ничего не
   удалять.
10. Независимо от результата вызвать штатный station rollback, `verify-clean` и
    status. Подтвердить отсутствие listener, guards, mount/patch, lock и worker.
11. Не повторять lifecycle автоматически. Если rollback не подтверждён — STOP,
    сохранить приватную диагностику.
12. Только если pairing и cleanup подтверждены, в отдельном разрешённом тесте
    проверить прямое управление; временная недоступность Алисы не входит в ECM
    lifecycle и не выполняется автоматически.

Шаблон команды намеренно не содержит реального Node ID или кода:

```powershell
pwsh -File scripts/start_maind_http_multi_admin_ecm.ps1 `
  -ConfirmToken I_APPROVE_ONE_MULTI_ADMIN_ECM_SESSION `
  -SshAlias <station-alias> -StationIPv4 <station-ipv4> `
  -StationIPv6 <station-ipv6> -ExpectedNodeId <fresh-node-id> `
  -MatterServerWebSocketUri ws://<matter-server>:5580/ws
```

## Восстановление и неоднозначные исходы

- Rollback восстанавливает только lifecycle Станции: штатный `platformd`,
  временные mount/patch, guards, lock и worker. Он не вызывает Matter
  `RevokeCommissioning`, `RemoveFabric`, factory reset или ACL writes.
- Если HTTP вернул timeout, окно могло открыться. POST не повторяется. Выполняются
  лишь разрешённые reads `WindowStatus`/`CommissionedFabrics`, затем rollback.
- Если Matter.js отказал после открытия окна, ждать естественного истечения окна;
  не вызывать Revoke автоматически.
- Если новая Fabric появилась при отсутствующем ожидаемом ответе, это успех с
  неоднозначной транспортной квитанцией: сохранить Fabric, сверить Matter.js node
  list и завершить cleanup. Никакого второго POST.
- Ошибка rollback/verify-clean — **NO-GO для любого следующего run** до ручной
  диагностики. Успешная новая Fabric при этом не удаляется.

## Controller deadlines (2026-11-09 update)

**CONFIRMED** — ECM now requires a station watchdog of at least 1500 seconds
and uses a monotonic `Stopwatch` for every controller-side deadline. For the
1500-second production setting the absolute deadlines, measured from before
staging, are:

| Phase | Absolute deadline | Local limits |
|---|---:|---|
| preparation and activation | 240 s | SSH connect/process 20–60 s |
| one-shot window POST | 360 s | wget 60 s; controller 75 s |
| Matter.js commissioning | 840 s | connect/send 10 s each; receive discovery + 60 s |
| readback | 1020 s | get_nodes 30 s; attribute read 45 s including transport margin |
| main scenario stop | 1140 s | no new state-changing step may start without its full minimum budget |
| rollback and verify-clean | 1380 s | rollback 120 s; verify-clean 60 s; status 30 s |
| independent watchdog | 1500 s | final 120-second station-side safety reserve |

Every operation receives the smaller of its local timeout and the remaining
phase budget. Rollback has a separate 240-second interval after the main
deadline. A forced SSH/WebSocket termination is treated as ambiguous and never
permits a repeated window POST or `commission_with_code`.

## Offline fault matrix

| Сценарий | Ожидаемое поведение | Результат |
|---|---|---|
| success | Fabric 1→2, node 0→1, rollback не меняет Fabric | PASS |
| HTTP 404 / 500 | terminal, POST claimed, no retry | PASS |
| incomplete response | terminal/ambiguous, secret не сохраняется | PASS |
| HTTP timeout | ambiguous window, no retry | PASS |
| повторный POST | отклонён allowlist/claim | PASS |
| SSH loss | ambiguous one-shot boundary, cleanup path | PASS |
| Matter.js failure | Яндекс Fabric остаётся, rollback | PASS |
| watchdog expiry | station rollback; модель Fabric не меняется | PASS |
| rollback error | clean=false, запрет нового run | PASS |
| Fabric появилась без ожидаемого ответа | reconcile, сохранить Fabric, no retry | PASS |

Это синтетические проверки state machine и allowlist, а не подтверждение реального
commissioning.

## Остаточные риски и GO/NO-GO

- **UNKNOWN** — реальный JSON response dedicated route точно совпадёт с
  `manualCode`/`qrCode` и route завершится менее чем за 60 секунд.
- **UNKNOWN** — сеть позволит Matter.js завершить PASE/CASE в пределах окна.
- **UNKNOWN** — Matter.js 1.5.5 response schema при реальном commissioning не
  содержит дополнительного промежуточного сообщения, требующего обработки.
- **INFERRED** — station rollback не удаляет новую Fabric: его shell path не
  содержит Matter fabric/window commands, а offline model подтверждает
  сохранение. Реально после успешного pairing это ещё не проверено.
- **GO (conditional)** — один аппаратный вызов допустим после отдельного
  разрешения, свежего пассивного preflight и проверки отсутствия recorder.
- **NO-GO** — при несовпадении Node ID, baseline не `[0,1,2]/0/1`, неготовом
  Matter.js, failed guards/watchdog, существующем lock/run или невозможности
  гарантировать rollback.
## Matter.js 1.5.5 structured failure capture

The next authorized commissioning run must persist only the allowlisted fields from the matched WebSocket error envelope: `error_code`, `reason`, `status`, `cluster_status`, a stage derived only from the documented `reason`, elapsed seconds, and `discovered_device` (`present`, `absent`, or `unknown`). The server's free-form `details` and the raw JSON envelope must never be written. Missing fields remain `null`; they are not synthesized.

Before opening the window, start a bounded passive capture on `enp5s0` for UDP/5353 and record only DNS-SD metadata needed to establish whether `_matterc._udp` was advertised (no pairing code or TXT values beyond the discriminator evidence required for matching). In parallel, record the monotonic timestamps of: window response, first matching `_matterc._udp` observation, `commission_with_code` send, and its matched response. A result is classified as:

- `not-discovered`: verify whether any matching `_matterc._udp` advertisement was observed on `enp5s0`;
- `passcode-mismatch`: device was discovered and PASE rejected the code;
- `invalid-payload`: local payload validation failed before discovery;
- `attestation-rejected`: discovery and PASE progressed to device attestation;
- `timeout` or `other`: do not infer a deeper stage unless `status`/`cluster_status` proves a Matter response.

Do not retry either the window POST or commissioning. Always preserve the existing one-shot claims, then rollback and independently verify clean.

### Confirmed cause of the first attempt (2026-11-09)

**CONFIRMED** — Matter.js discovered the lamp on `enp5s0`, selected its IPv6 link-local and IPv4 operational addresses, completed PASE, read the initial commissioning data, armed the fail-safe, and reached `OperationalCredentials.DeviceAttestation`. The server then rejected the device because its PAA is a test/development certificate while production trust policy is active. The installed implementation maps this path to `error_code=1` (`NodeCommissionFailed`) with `reason=attestation-rejected`. The server disarmed its Matter fail-safe before returning the WebSocket error.

**CONFIRMED** — `ENABLE_TEST_NET_DCL` is not set in the current container. Matter Server 1.5.5 exposes the official `--enable-test-net-dcl` / `ENABLE_TEST_NET_DCL` option. Enabling it changes trust policy and requires a separately authorized configuration change and controlled container restart; it was not changed during this diagnostic pass.

**SOURCE/CONFIRMED** — the 11-digit code is decoded by matter.js 0.18.0 `ManualPairingCodeCodec`; a synthetic encode/decode round trip preserved the short discriminator and setup PIN. The successful real PASE proves that neither manual-code decoding nor Enhanced Commissioning Window compatibility caused this failure.

### Next authorized attempt

1. Separately approve and apply `ENABLE_TEST_NET_DCL=true`, then verify the container is healthy, restart count and persistence, and that only the intended test-certificate trust is added.
2. Before opening the window, start a bounded `tcpdump` capture on `enp5s0` for UDP/5353; retain only timestamps and minimally redacted `_matterc._udp` matching evidence.
3. Run the existing one-shot lifecycle unchanged. Capture the allowlisted structured WebSocket diagnostic and monotonic elapsed time; never persist `details` or the raw response.
4. Confirm discovery, PASE, attestation, node creation, and `CommissionedFabrics`; regardless of outcome, perform station rollback and independent `verify-clean` without retrying commissioning.
