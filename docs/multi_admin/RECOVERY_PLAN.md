# План восстановления после ECM-попытки

Factory reset, RemoveFabric, ACL write, Wi-Fi change, automatic retry и
automatic Revoke/DELETE не допускаются.

## Если dedicated POST не открыл окно

Возможны: AccessDenied, UnsupportedCommand/runtime mismatch,
invalid WindowConfig, controller not ready, commissioner unavailable, CASE/session error,
window already open/busy.

Действия:

1. Не повторять POST.
2. Сохранить только non-secret error/status и run metadata.
3. Выполнить station rollback и independent verify-clean.
4. Read-only проверить `WindowStatus=0`, `CommissionedFabrics=1`.
5. Любой новый state-changing тест — только после разбора и нового
   разрешения.

## Если окно открылось, а Matter.js не нашёл лампу

1. Не открывать окно повторно.
2. Проверить `_matterc._udp`, IPv6, mDNS, UDP/5540, routes и time.
3. Проверить, что в Matter.js передан ровно returned code и
   `network_only=true`.
4. Дождаться 300-second timeout; read-only подтвердить
   `WindowStatus=0`.
5. Выполнить station rollback/verify-clean. DELETE/Revoke не вызывать
   без отдельного разрешения.

## Если PASE/commissioning начался, но завершился ошибкой

Сохранить redacted Matter.js/Станция status: discovery, PASE, attestation,
NOC/fabric stage. Не сохранять temporary code, verifier, salt, session keys.

- `CommissionedFabrics=1`: fabric не добавлена; ждать timeout, ничего
  не удалять.
- `CommissionedFabrics=2`: fabric уже добавлена; не вызывать
  RemoveFabric. Перейти к operational discovery/CASE/ACL диагностике.

## Если Fabric 2 есть, но direct control не работает

Проверить operational DNS-SD, IPv6 route, CASE logs, endpoint mapping и
ACL новой Fabric только read-only. Не удалять новую Fabric до точной
диагностики и нового разрешения.

## Если Яндекс потерял управление

1. Не удалять Fabric 2 автоматически.
2. Read-only проверить Fabric 1, current fabric attributes и Станция discovery.
3. Восстановить normal station process только штатным lifecycle; Quasar не
   менять.
4. Factory reset — только как последняя ручная мера после нового
   явного разрешения; не часть этого плана.
