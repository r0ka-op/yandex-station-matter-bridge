# Вклад в проект

Перед pull request:

1. Не добавляйте firmware, proprietary binaries, приватные ключи или runtime archives.
2. Не ослабляйте fail-closed guards и allowlists.
3. Добавьте offline regression test для изменённой ветки.
4. Запустите `pwsh -NoProfile -File tests/run_offline_tests.ps1`.
5. Очистите примеры и диагностику от адресов личной сети и уникальных идентификаторов.

Реальные device tests должны быть явно opt-in и никогда не запускаться стандартным offline test runner.

