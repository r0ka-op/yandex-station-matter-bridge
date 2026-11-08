> **Внимание:** команды изменяют runtime Станции. Они предназначены только для уже рутованной испытательной системы после проверки бинарников и read-only readiness. Не переносите параметры между моделями или firmware.

# Сценарии

Во всех примерах:

```powershell
$cfg = Import-PowerShellDataFile .\config.local.psd1
```

## Read-only

```powershell
# Devices only
& .\scripts\start_maind_http_runtime_test.ps1 @cfg -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST

# Current OnOff
& .\scripts\start_maind_http_runtime_test.ps1 @cfg `
  -ConfirmToken I_APPROVE_MAIND_HTTP_RUNTIME_TEST -ReadOnOffAttribute

# Current OnOff + CurrentLevel verification
& .\scripts\start_maind_http_light_state_verification.ps1 @cfg `
  -ConfirmToken I_APPROVE_READ_ONLY_LIGHT_STATE_VERIFICATION

# Descriptor, Level и Color discovery
& .\scripts\start_maind_http_capability_discovery.ps1 @cfg `
  -CapabilityDiscovery -ConfirmToken I_APPROVE_READ_ONLY_CAPABILITY_DISCOVERY

# Vendor cluster global attributes only
& .\scripts\start_maind_http_yandex_color_music_discovery.ps1 @cfg `
  -EnableVendorReadOnlyDiscovery `
  -ConfirmToken I_APPROVE_READ_ONLY_YANDEX_COLOR_MUSIC_DISCOVERY

# Полная read-only инвентаризация
& .\scripts\start_maind_http_full_inventory.ps1 `
  -Mode Runtime -EnableRuntimeInventory `
  -TargetNodeId $cfg.MatterNodeId `
  -SshAlias $cfg.SshAlias -StationIPv4 $cfg.StationIPv4 -StationIPv6 $cfg.StationIPv6 `
  -ConfirmToken I_APPROVE_ONE_READ_ONLY_FULL_MATTER_INVENTORY
```

Для offline-проверки оборудования и SSH не требуется:

```powershell
& .\scripts\start_maind_http_full_inventory.ps1 -Mode Offline
```

## Управляющие эксперименты

Эти сценарии физически меняют состояние устройства. Они сначала читают baseline, вооружают watchdog, выполняют одну allowlisted операцию, подтверждают readback и восстанавливают baseline.

```powershell
# OnOff: одно изменение и восстановление
& .\scripts\start_maind_http_onoff_control_test.ps1 @cfg `
  -EnableSingleOnOffChange `
  -ConfirmToken I_APPROVE_SINGLE_ONOFF_CHANGE_AND_RESTORE

# Небольшое изменение яркости
& .\scripts\start_maind_http_brightness_control_test.ps1 @cfg `
  -EnableBrightnessExperiment `
  -ConfirmToken I_APPROVE_SMALL_BRIGHTNESS_CHANGE_AND_RESTORE `
  -AllowTemporaryOn `
  -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE

# Визуальная яркость 64/254 с восстановлением
& .\scripts\start_maind_http_brightness_visual_test.ps1 @cfg `
  -EnableVisualBrightnessExperiment `
  -ConfirmToken I_APPROVE_VISUAL_BRIGHTNESS_64_AND_RESTORE `
  -AllowTemporaryOn `
  -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE

# Небольшое изменение Hue/Saturation
& .\scripts\start_maind_http_color_control_test.ps1 @cfg `
  -EnableColorExperiment `
  -ConfirmToken I_APPROVE_SMALL_COLOR_CHANGE_AND_RESTORE `
  -AllowTemporaryOn `
  -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE

# Визуальный цвет: level 64, hue delta 85, удержание около 3 секунд
& .\scripts\start_maind_http_color_visual_test.ps1 @cfg `
  -EnableVisualColorExperiment `
  -ConfirmToken I_APPROVE_VISUAL_COLOR_85_LEVEL_64_AND_RESTORE `
  -AllowTemporaryOn `
  -TemporaryOnConfirmToken I_APPROVE_TEMPORARY_ON_AND_RESTORE
```

Не запускайте управляющие сценарии, пока read-only discovery не подтвердил нужные endpoint, clusters, attributes и AcceptedCommandList.

