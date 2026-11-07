# Changelog

Все заметные изменения будут документироваться в этом файле. Формат основан на Keep a Changelog; версия проекта следует Semantic Versioning.

## [Unreleased]

### Community review snapshot

- Указан автор r0ka-op, добавлены NOTICE, краткое описание находки и безопасные примеры HTTP.
- Сборка архива переведена на явный allowlist исходников.
- Удалённые mutating entry points старой версии заблокированы; аппаратная работа требует переноса актуального lifecycle.
- Исправлен известный недостающий `return 1` в preflight старой версии (защита остаётся заблокированной).
- Пример проекта .NET переведён на net8.0 для соответствия требованиям документации.


### Added

- Переносимый runtime controller встроенного Matter HTTP API.
- Read-only discovery устройств, OnOff, Descriptor, Level, Color и vendor global attributes.
- Ограниченные OnOff/brightness/color experiments с readback и restoration.
- IPv4/IPv6 firewall guards, station-local watchdog, rollback и verify-clean.
- Offline integration, StrictMode, TLV, rollback и fault-injection tests.

