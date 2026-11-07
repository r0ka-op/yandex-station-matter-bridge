> **Исторический документ.** Описывает предыдущий source snapshot; не является отчётом о тестировании этого ознакомительного архива. См. README и docs/SHARING.md.

# Перенесённые исходники

Из рабочего исследовательского проекта отобраны следующие собственные файлы; исходное дерево не изменялось.

## Production

- `scripts/start_maind_http_runtime_test.ps1`
- `scripts/start_maind_http_onoff_control_test.ps1`
- `scripts/start_maind_http_capability_discovery.ps1`
- `scripts/start_maind_http_yandex_color_music_discovery.ps1`
- `scripts/start_maind_http_brightness_control_test.ps1`
- `scripts/start_maind_http_brightness_visual_test.ps1`
- `scripts/start_maind_http_color_control_test.ps1`
- `scripts/start_maind_http_color_visual_test.ps1`
- `scripts/start_maind_http_light_state_verification.ps1`
- `scripts/maind_http_response_helpers.ps1`
- `scripts/maind_http_onoff_control_helpers.ps1`
- `scripts/maind_http_capability_helpers.ps1`
- `scripts/maind_http_light_control_helpers.ps1`
- `scripts/maind_http_light_state_verification_helpers.ps1`
- `scripts/maind_http_runtime_test_remote.sh`
- `scripts/decode_matter_tlv.py`
- `scripts/backup_maind_http_temp_artifacts.ps1`
- `scripts/cleanup_completed_maind_http_artifacts.ps1`
- `scripts/mock_ssh_launcher/MockSshLauncher.csproj`
- `scripts/mock_ssh_launcher/Program.cs`

`scripts/maind_http_target_helpers.ps1` добавлен при выделении проекта, чтобы убрать жёстко заданные Node ID/endpoint.

## Tests

- `tests/run_full_matter_controller_audit.ps1`
- `tests/test_maind_http_controller.ps1`
- `tests/test_maind_http_onoff_control.ps1`
- `tests/test_maind_http_capability_discovery.ps1`
- `tests/test_maind_http_light_control.ps1`
- `tests/test_maind_http_light_state_verification.ps1`
- `tests/test_maind_http_strictmode.ps1`
- `tests/test_maind_http_visual_brightness_timing.ps1`
- `tests/test_matter_tlv_decoder.py`
- `tests/test_maind_http_rollback.py`
- `tests/maind_http_mock_server.py`
- `tests/mock_maind_ssh_transport.py`
- `tests/test_maind_http_watchdog_busybox.py`
- `tests/watchdog_isolated_busybox_runner.sh`
- `tests/watchdog_isolated_mock_wget.sh`

`tests/run_offline_tests.ps1` добавлен как единая воспроизводимая точка запуска. Live BusyBox watchdog test является отдельным opt-in device test и стандартным runner не вызывается.

Экспериментальные дубли, промежуточные версии, runtime evidence, reverse-engineering dumps и проприетарные бинарники не переносились.

