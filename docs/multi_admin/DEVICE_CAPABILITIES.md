# Возможности реальной YNDX-00560

Дата анализа: 2026-11-08. Источник устройства: сохранённая read-only инвентаризация
`inventory-20261108-002544-450`; команды в этом исследовании не вызывались.

## Маркировка

`CONFIRMED` — ответ реального устройства; `SOURCE` — внешний первичный источник;
`INFERRED` — технический вывод; `UNKNOWN` — данных недостаточно; `NOT TESTED` —
не проверено на оборудовании.

## Administrator Commissioning, endpoint 0, cluster `0x003C`

| Элемент | Значение | Статус | Evidence |
|---|---:|---|---|
| GeneratedCommandList `0xFFF8` | `[]` | CONFIRMED | `inventory_0124_ep0_cl60_at65528` |
| AcceptedCommandList `0xFFF9` | `[0, 1, 2]` | CONFIRMED | `inventory_0125_ep0_cl60_at65529` |
| EventList `0xFFFA` | `UNSUPPORTED_ATTRIBUTE` | CONFIRMED | `inventory_0126_ep0_cl60_at65530` |
| AttributeList `0xFFFB` | `[0,1,2,0xFFF8,0xFFF9,0xFFFB,0xFFFC,0xFFFD]` | CONFIRMED | `inventory_0127_ep0_cl60_at65531` |
| FeatureMap `0xFFFC` | `0` | CONFIRMED | `inventory_0128_ep0_cl60_at65532` |
| ClusterRevision `0xFFFD` | `1` | CONFIRMED | `inventory_0129_ep0_cl60_at65533` |
| WindowStatus `0` | `0` (WindowNotOpen) | CONFIRMED | `inventory_0130_ep0_cl60_at0` |
| AdminFabricIndex `1` | `null` | CONFIRMED | `inventory_0131_ep0_cl60_at1` |
| AdminVendorId `2` | `null` | CONFIRMED | `inventory_0132_ep0_cl60_at2` |

`AcceptedCommandList` реальной лампы объявляет:

- `0`: OpenCommissioningWindow — CONFIRMED;
- `1`: OpenBasicCommissioningWindow — CONFIRMED;
- `2`: RevokeCommissioning — CONFIRMED.

Это доказывает декларацию команд, но не успешный вызов, права текущего CASE-клиента,
корректность сериализации `maind` или совместимость с Home Assistant — NOT TESTED.

FeatureMap равен нулю, хотя команда Basic присутствует. В текущей XML-модели SDK bit 0
`BC` обозначает Basic Commissioning Method, поэтому это противоречие между FeatureMap и
AcceptedCommandList — CONFIRMED для устройства и требует осторожности. Команда `1` не
должна считаться рабочей только по AcceptedCommandList — INFERRED.

Первичный ответ сохранён, поэтому дополнительный read AcceptedCommandList уже не нужен.
На следующем сеансе его следует повторить только для обнаружения смены прошивки.

## Operational Credentials, endpoint 0, cluster `0x003E`

- SupportedFabrics `2` = `5` — CONFIRMED.
- CommissionedFabrics `3` = `1` — CONFIRMED.
- CurrentFabricIndex `5` = `1` — CONFIRMED.
- AcceptedCommandList = `[0,2,4,6,7,9,10,11]` — CONFIRMED.
- GeneratedCommandList = `[1,3,5,8]` — CONFIRMED.

Четыре свободных слота — INFERRED из счётчиков; возможность добавить fabric — UNKNOWN.
Содержимое NOCs, TrustedRootCertificates и существующие credentials не публикуются.

## Access Control

Сохранённый ACL содержит CASE-запись с privilege `5` (Administer), authMode `2`, subject
node ID `1` и fabricIndex `1` — CONFIRMED. Точное соответствие HTTP-запросов `maind` этому субъекту
не доказано — UNKNOWN. Успешные обычные invoke-команды показывают рабочую CASE-сессию,
но не доказывают Administer для `0x003C` — INFERRED.

## Источники стандарта

- [Administrator Commissioning XML](https://github.com/project-chip/connectedhomeip/blob/master/src/app/zap-templates/zcl/data-model/chip/administrator-commissioning-cluster.xml)
- [Operational Credentials XML](https://github.com/project-chip/connectedhomeip/blob/master/src/app/zap-templates/zcl/data-model/chip/operational-credentials-cluster.xml)
