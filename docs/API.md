# Matter HTTP API

Ниже перечислены маршруты и JSON, подтверждённые статическим анализом `maind`, встроенным UI и реальными запросами. Числа в примерах условные.

## `GET /devices`

Возвращает JSON со связанными Matter nodes. На испытанном устройстве корень был массивом, но production parser не предполагает форму заранее и сохраняет raw body до разбора.

```json
[{"nodeId":4660,"endpoints":[0,1],"macAddress":"REDACTED"}]
```

## `POST /interaction/readAttribute`

```json
{"nodeId":4660,"endpointId":1,"clusterId":6,"attributeId":0}
```

Ответ содержит Matter errors и values с `rawValue` в виде hex Matter TLV. HTTP 2xx недостаточно: проверяются структура, Matter errors, identity атрибута и ожидаемый TLV type.

## `POST /interaction/invokeCommand`

Общая подтверждённая схема:

```json
{"nodeId":4660,"endpointId":1,"clusterId":6,"commandId":1,"fields":{}}
```

OnOff: cluster `6`, `Off=0`, `On=1`, пустой `fields`.

MoveToLevel: cluster `8`, command `0`:

```json
{"nodeId":4660,"endpointId":1,"clusterId":8,"commandId":0,"fields":{"level":64,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}
```

MoveToHueAndSaturation: cluster `768`, command `6`:

```json
{"nodeId":4660,"endpointId":1,"clusterId":768,"commandId":6,"fields":{"hue":85,"saturation":244,"transitionTime":5,"optionsMask":0,"optionsOverride":0}}
```

Успех invoke подтверждается допустимой response structure/status и обязательным readback. Поле `errors` может отсутствовать; само его отсутствие не доказывает успех.

`/interaction/writeAttribute` обнаружен как потенциально изменяющий маршрут, но production allowlists проекта его запрещают. Корневой `/` в реальном тесте возвращал `404 Not found`; это не transport failure.

