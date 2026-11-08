# Интеграция реальной Matter-инвентаризации

Источник: приватный read-only дамп `inventory-20261108-002544-450`. В этот
репозиторий перенесён только обезличенный capability-fixture.

## Реализовано

- Endpoint выбирается по `GET /devices`, Descriptor DeviceTypeList и ServerList,
  а не по фиксированному Node ID.
- Для OnOff, LevelControl и ColorControl читаются AttributeList,
  AcceptedCommandList и FeatureMap; команда допускается только если объявлена.
- `MoveToColorTemperature` исключена из базового invoke-allowlist. Она появляется
  только при явном `color_temp=true`, после проверки command 10, атрибута
  ColorTemperatureMireds и физических границ 154..370 mired.
- Поля command 10: `colorTemperatureMireds`, `transitionTime`, `optionsMask`,
  `optionsOverride`. Схема сверена с официальной Matter-моделью, но реальный
  вызов через новый клиент ещё не выполнен.
- BusyBox wget transport возвращает фактический HTTP status. HTTP 500 больше не
  маскируется как потеря SSH/TCP.
- Только `UNSUPPORTED_ATTRIBUTE` считается допустимым отсутствующим атрибутом.
  `ACCESS_DENIED`, неизвестная Matter-ошибка и HTTP-ошибка остаются фатальными.
- Обезличенный fixture не содержит оригинальный Node ID, MAC, serial, адреса,
  Fabric ID, сертификаты или ключи.

## Реальные факты, использованные клиентом

- Endpoint 1: device type `0x010D` (Extended Color Light).
- OnOff commands включают 0 и 1; LevelControl включает command 0;
  ColorControl включает command 6 и command 10.
- Color FeatureMap/ColorCapabilities: `0x19`.
- Color temperature: 154..370 mired, консервативный UI-диапазон 2703..6493 K.
- Два чтения ModeSelect вернули HTTP 500; это не классифицируется как
  `UNSUPPORTED_ATTRIBUTE`.

## Проверки

- `python -m unittest discover -s tests -t .`: 70 тестов, PASS; четыре Unix-shell
  теста guard пропущены на Windows из-за отсутствия BusyBox/sh.
- `python -m compileall -q src tests`: PASS.
- Inventory helper tests: 13/13 PASS.
- Inventory production contracts: 13/13 PASS.
- PowerShell AST изменённого inventory helper: PASS.

Target-shell lifecycle отдельно был проверен ранее в `ambi-lamp-research`; в
этой задаче оборудование не использовалось и Station postflight не выполнялся.

## Остаточные риски

- Новый endpoint/capability path и обновлённый wget status parser проверены mock-
  тестами, но ещё не проверены через реальную Станцию.
- Command 10 объявлен лампой и его схема подтверждена спецификацией, но реальный
  вызов не выполнен; поэтому opt-in обязателен.
- CLI не активирует и не отключает API: следующий тест должен выполняться внутри
  существующего bounded lifecycle с firewall guards, watchdog и rollback.
