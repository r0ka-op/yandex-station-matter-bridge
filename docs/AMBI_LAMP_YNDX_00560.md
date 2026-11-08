# Яндекс Эмби Лампа YNDX-00560

## Подтверждённые факты

В испытанной Matter fabric световой endpoint имел номер `1`. Operational Node ID зависит от установки и намеренно не публикуется: пользователь обязан получить свой актуальный Node ID через `/devices`.

Descriptor ServerList endpoint 1 содержал стандартные clusters Level Control (`8`) и Color Control (`768`), а также vendor-specific `0x132FFC06`, `0x132FFC0A`, `0x132FFC0C`.

Подтверждённые атрибуты/возможности:

- Level CurrentLevel (`cluster=8`, `attribute=0`);
- Level AcceptedCommandList: `[0,1,2,3,4,5,6,7]`;
- ColorCapabilities и FeatureMap: `25`;
- ColorMode `0` (Hue/Saturation) в момент discovery;
- Hue, Saturation, CurrentX, CurrentY, ColorTemperatureMireds читаются;
- Color AcceptedCommandList: `[0,1,2,3,4,5,6,7,8,9,10,71,75,76]`;
- реальные On/Off, MoveToLevel и MoveToHueAndSaturation были выполнены с readback и восстановлением исходного состояния.
- Color Temperature объявлена в диапазоне 154–370 mired; команда MoveToColorTemperature присутствует в AcceptedCommandList, но вызов через новый Python-клиент на реальном устройстве пока не проверялся.

## Vendor-кластеры

Наличие vendor cluster `0x132FFC06` на endpoint доказано Descriptor ServerList. В `maind` найдены имена YandexColorMusic (`SetEnable`, `SetAnimation`, AutoPlay/AutoRun), однако сопоставление каждого command/attribute с wire schema устройства не завершено. Проект разрешает только read-only discovery глобальных атрибутов этого cluster.

Read-only инвентаризация `0x132FFC0C` обнаружила режимы `None`, `Color`, `Scene`, `Color music`. Это подтверждает объявленные режимы, но не разрешает выполнять неизвестные vendor-команды.

## Не подтверждено и не поддерживается

- неизвестные vendor-команды `0x132FFC06`;
- семантика неизвестных полей clusters `0x132FFC0A` и `0x132FFC0C`;
- Identify.TriggerEffect как способ запуска цветомузыки;
- поддержка тех же возможностей на другой ревизии лампы/firmware.

Наличие символов или обработчиков в `maind` не доказывает поддержку cluster конкретным устройством.

