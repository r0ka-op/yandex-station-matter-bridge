# Исследование Multi-Admin для Yandex YNDX-00560

## Краткий вывод

- Реальная лампа объявляет OpenCommissioningWindow, OpenBasicCommissioningWindow и
  RevokeCommissioning — CONFIRMED.
- Свободно четыре fabric slots было подтверждено до теста; добавление второй Fabric
  впоследствии завершено успешно — HARDWARE PASS.
- Безопасный предпочтительный путь по стандарту существует: ECM с временным кодом — SOURCE.
- Generic invoke через `maind` остался NO-GO, но штатный dedicated
  `/commissioning/window` использует CommissioningWindowOpener и подтверждён на железе.
- У Яндекса не найден документированный UI «поделиться Matter-устройством» для Эмби Лампы.
- Этот проект получил подтверждённый успешный Multi-Admin именно YNDX-00560.

## Фактическая база

Локальная инвентаризация: 263 HTTP-запроса, 237 успешных чтений, 2 endpoint, 22 server
clusters. Она выполняла только GET `/devices` и POST `/interaction/readAttribute`.
`invokeCommand` в этом сеансе не использовался.

Полные приватные результаты не копируются в Git. Публичная сводка: `docs/REAL_INVENTORY.md`.

## Реализация `maind`

Подтверждён контракт `/interaction/invokeCommand` с JSON `fields`; успешно проверены
OnOff (пусто) и числовые поля Level/Color. Текущий Python client allowlist допускает
только световые команды. Его TLV-модуль декодирует ответы, но request fields передаются
как JSON и не кодируются клиентом в Matter TLV.

Следовательно, критическая точка находится внутри закрытой HTTP реализации `maind`:
она должна знать schema cluster `0x003C`, octet-string representation и Timed Invoke.
Логи этого не доказывают. Добавлять state-changing command в обычный client нельзя.

## Взаимодействие с Яндексом и сообществом

Официальная справка Яндекса описывает привязку Эмби Лампы к выбранной Станции и говорит,
что устройства Яндекса Matter over Wi-Fi можно подключать к стороннему Matter-хабу, но
не описывает sharing уже подключённой Эмби Лампы или Multi-Admin UI.

AlexxIT/YandexStation поддерживает YNDX-00560 через сущность умного дома Яндекса; issue
#759 подтверждает модель и облачное/интеграционное управление, но не прямой Matter
commissioning. Issue #723 содержит раннее пользовательское предположение «не Matter»;
оно опровергается нашей реальной Matter-инвентаризацией и не является тестом Multi-Admin.

Home Assistant документирует sharing для уже подключённых Apple/Google Matter devices,
но Yandex не присутствует в этом официальном UI flow. Возможен ручной временный code,
если текущий Yandex controller откроет окно.

Источники:

- [Яндекс: подключить Эмби Лампу](https://alice.yandex.ru/support/ru/ambient-lamp/connect-station)
- [Яндекс: Matter devices](https://alice.yandex.ru/support/ru/smart-home/supported-matter-devices)
- [AlexxIT issue #759](https://github.com/AlexxIT/YandexStation/issues/759)
- [AlexxIT issue #723](https://github.com/AlexxIT/YandexStation/issues/723)
- [Home Assistant Matter sharing](https://www.home-assistant.io/integrations/matter/#sharing-a-device-across-platforms)

## Решение

Продолжать только ECM-first. Basic оставить fallback из-за FeatureMap=0 и зависимости от
постоянного setup code. Первое аппаратное действие — повторный read-only срез `0x003C`
и `0x003E`, а не открытие окна.
