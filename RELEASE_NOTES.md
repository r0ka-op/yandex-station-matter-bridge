# Release notes: integrated research and `ymatter` client

Prepared on 2026-11-08.

## Included

- Installable Python client in `client/` with CLI, SSH-exec transport,
  discovery, state/readback, On/Off, brightness, Hue/Saturation,
  experimental Color Temperature, MQTT, and Home Assistant Discovery.
- Current research lifecycle with unique `run_id`, global lock, IPv4/IPv6
  guards, watchdog, fail-closed rollback, and `verify-clean`.
- Full read-only inventory entry point and structured station readiness
  diagnostics.
- Sanitized documentation derived from the successful hardware inventory;
  private raw captures are not included.
- CI for client tests and packaging, production-controller mock execution,
  shell validation, PowerShell analysis, publication safety, and links.

## Evidence represented in this release

- The station's built-in Matter HTTP API, temporary activation, isolation,
  and rollback were exercised on hardware.
- The lamp was read and inventoried through the API: 263 requests and 237
  successful reads.
- Research controllers exercised On/Off, brightness, and Hue/Saturation on
  hardware with state restoration.
- The integrated production-entry harness passes 80/80 offline cases; the
  target shell lifecycle model passes 12/12 cases; inventory contracts pass
  13/13 cases.
- The Python client passes 70 tests on Windows. Four Unix-only guard tests are
  explicitly skipped there and are intended to run in Linux CI.

## Experimental or not yet validated on hardware

- Real lamp control through the newly integrated Python client.
- Color Temperature through `ymatter` (disabled by default).
- Long-running MQTT/Home Assistant operation.
- A permanent safe API activation mode.
- Independent pairing of the lamp to another Matter fabric.

No hardware command is retried automatically after an uncertain result. A
real client session must capture baseline state and confirm restoration before
the station API is rolled back.
