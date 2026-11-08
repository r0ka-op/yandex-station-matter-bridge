# Совместимость

## Испытанная конфигурация

| Компонент | Подтверждённое значение |
|---|---|
| Станция | Яндекс Станция Мини 2 |
| Firmware | `0.369.1.46.4793643989.20261020.299` |
| Quasar | `3.21` |
| `maind` SHA-256 | `7ff114e08d46d48394f9d794f89dc941f3b217bdcd3ff1ef46f1cd80fada6ec1` |
| `quasar_launcher2` SHA-256 | `e7af45d49ea9626c7bfc1d72c648663c82e024a8c9d538b0aa6f8317288f5054` |
| Matter-устройство | Яндекс Эмби Лампа YNDX-00560 |
| Host controller | Windows 11, PowerShell 7 |
| Full read-only inventory | 263 запроса, 237 успешных чтений, 2 endpoint, 22 server-кластера |

## Не подтверждено

- другие модели Яндекс Станций;
- другие firmware/Quasar/`maind` builds;
- сохранение имён configuration patch и lifecycle после OTA;
- иные supervisor delays и restart policies;
- любые другие Matter-устройства, даже если они используют стандартные clusters;
- macOS/Linux host controller.
- реальное управление через новый Python-клиент `ymatter`;
- постоянная Home Assistant/MQTT-интеграция;
- независимое Matter-сопряжение, несмотря на `SupportedFabrics=5` и `CommissionedFabrics=1`.

После OTA сначала сравните hashes, listener bind, auth model, configuration loader и supervisor behavior. До этого управляющие сценарии использовать нельзя.

