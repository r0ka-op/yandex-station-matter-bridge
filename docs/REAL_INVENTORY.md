# Обезличенные результаты реальной Matter-инвентаризации

Дата: 2026-11-07—08. Устройство: Яндекс Эмби Лампа YNDX-00560, уже сопряжённая со штатным Matter-контроллером Яндекс Станции.

Документ не содержит Node ID, MAC, серийный номер, Fabric ID, сертификаты, ключи или адреса частной сети. Полный приватный дамп в репозиторий не включается.

## Метод

В одном ограниченном сеансе использовались только:

- `GET /devices`;
- `POST /interaction/readAttribute`.

API был временно активирован под IPv4/IPv6 firewall isolation. После 263 HTTP-запросов выполнены rollback и независимый postflight. Получено 237 успешных чтений. `invokeCommand`, `writeAttribute` и vendor-команды не использовались.

## Endpoint и кластеры

Обнаружены два endpoint и 22 server-кластера.

Endpoint 0:

- Descriptor `0x001D`;
- Access Control `0x001F`;
- Basic Information `0x0028`;
- OTA Requestor `0x002A`;
- General Commissioning `0x0030`;
- Network Commissioning `0x0031`;
- General Diagnostics `0x0033`;
- Software Diagnostics `0x0034`;
- Wi-Fi Network Diagnostics `0x0036`;
- Administrator Commissioning `0x003C`;
- Operational Credentials `0x003E`;
- Group Key Management `0x003F`.

Endpoint 1 объявлен как Extended Color Light и содержит Groups, Identify, OnOff, Level Control, Descriptor, Mode Select `0x0050`, Color Control `0x0300` и vendor-кластеры `0x132FFC06`, `0x132FFC0A`, `0x132FFC0C`.

## Свет и цвет

Color Control объявляет Hue/Saturation, XY и Color Temperature. Фактические границы Color Temperature: 154–370 mired (примерно 6493–2703 K). AcceptedCommandList включает MoveToColorTemperature `0x0A`, но реальный вызов этой команды через новый Python-клиент не выполнялся.

## Vendor-кластеры

В читаемом списке режимов `0x132FFC0C` обнаружены:

- None;
- Color;
- Scene;
- Color music.

Это подтверждает наличие объявленных режимов, но не раскрывает семантику неизвестных vendor-полей и не доказывает безопасную схему их активации.

## Commissioning

- SupportedFabrics: 5;
- CommissionedFabrics: 1;
- CurrentFabricIndex: 1;
- Administrator Commissioning WindowStatus: 0;
- AdminFabricIndex и AdminVendorId: null.

Свободная ёмкость таблицы Fabric не означает, что commissioning window можно открыть или что второй независимый контроллер успешно присоединится. Multi-Admin не проверялся.

## Ошибки

- 24 результата `UNSUPPORTED_ATTRIBUTE` — Matter-статусы необязательных чтений;
- два чтения атрибутов Mode Select завершились HTTP 500 с пустым телом.

HTTP 500 не классифицируется как `UNSUPPORTED_ATTRIBUTE` или транспортная ошибка.
