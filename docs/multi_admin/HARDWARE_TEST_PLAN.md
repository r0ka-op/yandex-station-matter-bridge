# План следующего аппаратного сеанса

## Статус

HARDWARE PASS — технические blockers Timed Invoke и binary verifier/salt
устранены через штатный `POST /commissioning/window`. План выполнен один раз:
окно, PASE, attestation, AddNOC, CommissioningComplete, rollback и verify-clean
подтверждены. Для любого нового вызова по-прежнему требуется отдельное разрешение.

NO-GO — не использовать `/interaction/invokeCommand` для cluster
`0x003C`: JSON parser не имеет такой dispatch branch.

## Разовая подготовка lifecycle

До сеанса подготовить новый ограниченный mode, не меняя
механизмы activation/guards/watchdog/rollback. Allowlist:

- `GET /devices`;
- только baseline/read-back `readAttribute` для `0x003C`/`0x003E`;
- ровно один `POST /commissioning/window` с exact schema;
- никаких DELETE, generic invoke, writeAttribute или automatic retry.

Сохранить: IPv4/IPv6 guards до listener, independent watchdog 360 s,
unique run_id, global lock, firmware/hash preflight, Node ID pinning, fail-fast,
rollback и independent verify-clean. Не удалять старые runs.

## Точный сценарий одного ECM-вызова

### 1. Passive baseline

1. Подтвердить SSH Станции/Ubuntu, текущие IPv4/IPv6/routes.
2. Подтвердить firmware, SHA-256 `maind`, normal `platformd`, TCP/8765 closed.
3. Проверить отсутствие active lock, stale patch/mount, lifecycle processes.
4. Подтвердить Matter.js Server healthy, persistence, WebSocket, nodes=`0`,
   IPv6/mDNS готовы. Не перезапускать без необходимости.

### 2. Guarded activation после явного разрешения

1. Пройти полный preflight; не обходить refusal.
2. Установить и проверить IPv4/IPv6 guards.
3. Запустить/проверить independent watchdog до restart.
4. Активировать temporary API штатным lifecycle.
5. Подтвердить loopback-only и недоступность TCP/8765 по всем
   LAN IPv4/IPv6 адресам Станции.

### 3. Read-only precondition

1. `GET /devices`: ровно ожидаемый private Node ID.
2. Прочитать `AcceptedCommandList=[0,1,2]`, `WindowStatus=0`.
3. Прочитать `SupportedFabrics=5`, `CommissionedFabrics=1`,
   `CurrentFabricIndex=1`.
4. Любое несовпадение/error → немедленный station rollback, без POST.

### 4. Один state-changing POST

1. В оперативной памяти создать CSPRNG discriminator `0..4095`.
2. Сформировать ровно:

   ```json
   {"nodeId": 4660, "discriminator": 2748, "timeout": 300}
   ```

   `4660`/`2748` — только пример; подставить private Node ID/fresh
   discriminator.
3. Вызвать `POST /commissioning/window` ровно один раз.
4. На error/timeout/Node mismatch — не повторять; перейти к rollback.
5. На success держать `manualCode`/`qrCode` только в памяти;
   не печатать, не сохранять в JSON/log/Git.
6. Read-only подтвердить enhanced `WindowStatus`.

### 5. Matter.js commissioning

1. Немедленно передать in-memory pairing code в ранее проверенный
   `commission_with_code`, `network_only=true`, `discovery_timeout_s=300`.
2. Не запускать discovery/commissioning заранее и не делать retry.
3. На success проверить Matter.js node list и direct read/control.
4. Read-only прочитать `CommissionedFabrics`; ожидается `2`.
5. Проверить, что Яндекс по-прежнему управляет лампой.
6. Временно сделать Станцию недоступной только отдельным
   согласованным шагом; затем проверить direct control и восстановить
   обычную работу Станции.

### 6. Mandatory station cleanup

1. Выполнить штатный rollback независимо от commissioning result.
2. Independent verify-clean: TCP/8765 closed, stock `platformd`, no guards,
   mounts/patches/locks/watchdogs/experimental processes.
3. Если cleanup не PASS — не повторять activation; остановиться
   с диагностикой.

CONFIRMED — station rollback восстанавливает только локальный
`platformd`/guards/patch state и не вызывает RemoveFabric на лампе.

## Отказ/восстановление

- POST error: записать только non-secret status, rollback; без retry.
- Window opened, commissioning failed: дождаться timeout и read-only
  подтвердить `WindowStatus=0`.
- `CommissionedFabrics=1`: ничего не удалять; анализировать
  mDNS/PASE/CASE logs без codes/credentials.
- `CommissionedFabrics=2`, но direct control failed: сохранить Fabric,
  проверить ACL/session/network; без RemoveFabric.
- Не вызывать DELETE/Revoke, RemoveFabric, ACL write, Wi-Fi change или
  factory reset без нового разрешения.

## Перед первой попыткой

1. Review нового exact-route lifecycle mode и offline mock tests.
2. Зафиксировать private Node ID только в private run config.
3. Подготовить in-memory handoff response code → Matter.js WebSocket;
   исключить shell history/transcript/debug logging.
4. Получить явное разрешение на один POST и одну commissioning
   attempt.
