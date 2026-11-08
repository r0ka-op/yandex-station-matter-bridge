# Changelog

Все заметные изменения будут документироваться в этом файле. Формат основан на Keep a Changelog; версия проекта следует Semantic Versioning.

## [Unreleased]

### Integrated client and current lifecycle

- Добавлен Python-клиент `ymatter` в `client/`, MQTT bridge и Home Assistant Discovery.
- Перенесён актуальный lifecycle с `run_id`, global lock, structured preflight diagnostics, watchdog и `verify-clean`.
- Добавлена полная read-only инвентаризация и обезличенная сводка её реальных результатов.
- Приватные адреса, идентификаторы и runtime-артефакты исключены; Node ID и endpoint задаются явно.
- Устаревшие release-документы перенесены в `docs/archive/`.


### Added

- Переносимый runtime controller встроенного Matter HTTP API.
- Read-only discovery устройств, OnOff, Descriptor, Level, Color и vendor global attributes.
- Ограниченные OnOff/brightness/color experiments с readback и restoration.
- IPv4/IPv6 firewall guards, station-local watchdog, rollback и verify-clean.
- Offline integration, StrictMode, TLV, rollback и fault-injection tests.

