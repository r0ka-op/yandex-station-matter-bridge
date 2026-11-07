# Security Policy

## Supported versions

До первого публичного релиза security fixes применяются только к текущей ветке разработки.

## Сообщение об уязвимости

После публикации используйте private vulnerability reporting / Security Advisory репозитория GitHub. Не прикладывайте публично runtime archives, конфигурацию SSH, адреса личной сети, MAC, Matter credentials, Wi-Fi данные или полные системные журналы.

В отчёте достаточно указать версию проекта, модель/firmware без уникальных идентификаторов, минимальные шаги воспроизведения и очищенный фрагмент журнала.

Изменения считаются security-sensitive, если они затрагивают firewall ordering, IPv6, configuration patch, lifecycle `platformd`, watchdog, allowlists, restoration readback или порядок снятия guards. Для них обязательны integration и fault-injection tests.

