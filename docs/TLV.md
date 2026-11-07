# Matter TLV

`readAttribute` возвращает `rawValue` как hex-представление Matter TLV. Проект декодирует типобезопасно: тип элемента проверяется до значения.

Подтверждённые примеры:

- `0x08` — anonymous Boolean `false`;
- `0x09` — anonymous Boolean `true`;
- CurrentLevel — anonymous unsigned integer подходящей ширины;
- массивы, включая Descriptor ServerList и command lists, разбираются как контейнеры.

Boolean нельзя принимать как unsigned integer только потому, что payload похож на число. Null, несколько корневых элементов, неправильный tag/type и trailing bytes являются диагностической ошибкой.

```powershell
python .\scripts\decode_matter_tlv.py --hex 0x08
```

Точный CLI смотрите через `--help`; unit tests находятся в `tests/test_matter_tlv_decoder.py`.

