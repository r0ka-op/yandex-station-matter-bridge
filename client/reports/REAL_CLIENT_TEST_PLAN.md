# План одного ограниченного аппаратного сеанса ymatter-bridge

Статус: подготовлен, но не выполнен. Этот документ не разрешает оставлять
`matter.httpControl` включённым и не заменяет проверенный lifecycle из
`ambi-lamp-research`.

## Подтверждённая основа

- Клиент работает через `ssh-exec`: OpenSSH запускает BusyBox `wget` на Станции,
  а запрос идёт только к `127.0.0.1:8765`. Dropbear direct-tcpip не используется.
- Цель выбирается из `GET /devices` и Descriptor, без жёсткой привязки к Node ID.
- Перед командами проверяются ServerList, AttributeList и AcceptedCommandList.
- Реальная лампа объявила Extended Color Light, OnOff 0/1, MoveToLevel 0,
  MoveToHueAndSaturation 6 и MoveToColorTemperature 10.
- Физический диапазон температуры: 154..370 mired (2703..6493 K).
- Формат command 10 подтверждён официальной Matter-моделью:
  `colorTemperatureMireds`, `transitionTime`, `optionsMask`, `optionsOverride`.
  Реальный вызов command 10 через этот клиент пока не проверен, поэтому он
  разрешается только явным `color_temp=true`.

Источник схемы: [connectedhomeip lighting-app.matter](https://github.com/project-chip/connectedhomeip/blob/master/examples/lighting-app/lighting-common/lighting-app.matter).

## Предварительная конфигурация

Создать локальный, исключённый из Git `config.real-test.toml`. Node ID можно не
указывать; endpoint будет выбран по Descriptor. На первом проходе оставить
`color_temp=false`.

```toml
[station]
ssh_alias = "<existing-ssh-alias>"
ip = "<station-lan-ip>"
transport = "ssh-exec"
api_port = 8765

[lamp]
name = "Ambi Lamp test"
color_temp = false
min_kelvin = 2703
max_kelvin = 6493

[safety]
require_guard = true
allow_unknown_firmware = false
```

## Границы сеанса

1. Использовать только проверенный временный lifecycle `ambi-lamp-research`:
   firewall guards IPv4/IPv6 устанавливаются до listener, затем watchdog,
   временный patch, адресный lifecycle platformd. API не открывается в LAN.
2. Не запускать команды клиента, пока lifecycle не подтвердил listener,
   guards и отрицательные LAN-пробы.
3. Один сеанс, без автоматического повторного запуска. Общий бюджет — не более
   watchdog deadline минус 60 секунд на гарантированный rollback.
4. Сначала сохранить полный baseline `ymatter state`: OnOff, CurrentLevel,
   ColorMode, Hue, Saturation и ColorTemperatureMireds.
5. После каждого изменения требовать успешный readback. При первом неподтверждённом
   readback прекратить дальнейшие изменения и начать восстановление.
6. До отключения API восстановить активный цветовой режим, цвет, уровень и OnOff;
   затем повторно прочитать все baseline-атрибуты.
7. Только после подтверждённого восстановления выполнить rollback API,
   `verify-clean`, проверить отсутствие TCP/8765 и лишь затем снять guards.

## Команды клиента внутри уже защищённого API-окна

Из корня объединённого репозитория в отдельном PowerShell (после
`python -m pip install ./client`):

```powershell
$cfg = '.\config.real-test.toml'
python -m ymatter.cli -c $cfg doctor
python -m ymatter.cli -c $cfg devices
python -m ymatter.cli -c $cfg discover
python -m ymatter.cli -c $cfg state
```

После сохранения baseline и вооружения station-side восстановления выполнить по
одной операции с readback между строками:

```powershell
python -m ymatter.cli -c $cfg on
python -m ymatter.cli -c $cfg brightness 25 --transition 0.5
python -m ymatter.cli -c $cfg color 120 90 --transition 0.5
python -m ymatter.cli -c $cfg state
```

Температуру проверять последней и только отдельным явно согласованным шагом:
после изменения `color_temp=true`, повторного `doctor`/`discover` и подтверждения,
что command 10 и границы всё ещё объявлены.

```powershell
python -m ymatter.cli -c $cfg temp 4000 --transition 0.5
python -m ymatter.cli -c $cfg state
```

Непосредственно после проверки восстановить baseline. Для точного восстановления
не округлять сохранённые Matter level/hue/saturation/mireds через визуальные UI-
значения: lifecycle-обёртка должна передать сохранённые raw значения production
`Lamp`/`MaindClient` и подтвердить их readback. Rollback platformd сам по себе
состояние лампы не восстанавливает.

## Что считать успехом

- `doctor`, `devices`, `discover`, `state` успешны через SSH → BusyBox wget.
- Фактический endpoint соответствует типу 0x010D и объявляет используемые команды.
- OnOff, уровень, HS и (если отдельно разрешено) температура подтверждены readback.
- Все исходные атрибуты восстановлены до выключения API.
- lifecycle сообщает rollback PASS и verify-clean PASS; TCP/8765 закрыт, guards,
  patch, mount, watchdog и run lock отсутствуют.

## Остаточный организационный риск

CLI намеренно не управляет lifecycle Станции. Поэтому команды выше должны быть
выполнены только внутри контролируемого окна существующего audited-контроллера,
который владеет watchdog и rollback. Не запускать CLI против вручную оставленного
API и не превращать этот план в постоянный сервис.
