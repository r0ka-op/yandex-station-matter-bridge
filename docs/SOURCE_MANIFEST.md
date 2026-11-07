> **Исторический документ.** Описывает предыдущий source snapshot; не является отчётом о тестировании этого ознакомительного архива. См. README и docs/SHARING.md.

# Source manifest

Проект выделен из внутреннего исследовательского дерева. Перенесены только собственные production controllers/helpers, тестовый контур и заново оформленная публичная документация.

Не перенесены:

- `maind`, `quasar_launcher2` и любые части firmware;
- disassembly, core dumps и vendor assets;
- реальные runtime logs, HTTP bodies и snapshots;
- IP/MAC/SSH конфигурация лабораторной сети;
- Matter/Wi-Fi credentials и ключевой материал;
- исторические промежуточные скрипты и отчёты.

Полный перечень файлов релиза формируется `tools/build_source_release.ps1` и фиксируется внутри ZIP через `MANIFEST.sha256`.

