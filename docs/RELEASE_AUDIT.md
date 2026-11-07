> **Исторический документ.** Описывает предыдущий source snapshot; не является отчётом о тестировании этого ознакомительного архива. См. README и docs/SHARING.md.

# Аудит исходного релиза

Дата подготовки: 2026-11-07.

## Выполнено

- все PowerShell-файлы разобраны AST без ошибок;
- Python sources прошли `py_compile`;
- все shell helpers прошли `sh -n` через WSL;
- Matter TLV decoder tests — PASS;
- rollback model — PASS;
- StrictMode tests — PASS;
- production entry points выполнены offline через production helpers и mock SSH/HTTP/device backend;
- end-to-end/fault-injection audit: 65/65 PASS;
- общий runner: 13/13 групп PASS;
- build outputs удалены перед упаковкой;
- source ZIP исключает `.git`, `results`, local config, diagnostics и build outputs.

Стандартный runner не подключается к Станции (`station_contacted=false`). Optional BusyBox device test не входит в него.

## Privacy/security scan

В публикуемом дереве не обнаружены:

- адреса и SSH alias лабораторной сети;
- пользовательские home paths;
- реальные MAC;
- private keys, access tokens, Wi-Fi/Matter credentials;
- firmware/ELF/shared objects/dumps/captures;
- runtime logs и HTTP evidence реального устройства;
- commit trailers или metadata с нежелательным соавторством.

Node ID `258` встречается только как документированный результат одного эксперимента и как fixture offline-тестов. Production принимает Node ID и endpoint как обязательные параметры.

## Инструменты

PSScriptAnalyzer не был установлен в среде сборки, поэтому его результат отсутствует. Это не заменено утверждением об успешном анализе; перед публичным релизом рекомендуется отдельный запуск PSScriptAnalyzer на чистой машине.

