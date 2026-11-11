# 05 · Color music without a running Yandex Station

[← Controls](03_CONTROL_EN.md) · [Start](00_START_EN.md) · [Troubleshooting](04_RECOVERY_EN.md) · [Русский](05_COLOR_MUSIC_RU.md)

**Hardware finding reported on November 11, 2026:** YNDX-00560 independently enabled Color music via Matter.js and visibly pulsed when Ubuntu replayed UDP/4048 packets. This was repeated with the Yandex Station **physically powered off**.

> These are **hardware experiment findings**, not yet a publicly reproducible install. The research scripts and vendor-patched image remain in a local workspace and are **not published** in this repository. No new commissioning is required for an already paired lamp.

## Two mechanisms

~~~mermaid
flowchart LR
  subgraph Linux["Ubuntu / independent host"]
    M["Matter.js<br/>Fabric 2"]
    P["UDP frame source<br/>replay"]
  end
  M -->|"Matter UDP/5540<br/>SetEnable + SetAnimation"| L["YNDX-00560"]
  P -->|"UDP/4048<br/>490 B per frame"| L
  Y["Yandex Station<br/>Fabric 1"] -. "Not required during<br/>verified replay" .- L
~~~

**Matter** enables Color music; the separate **UDP** feed supplies spectrum-like data. With the mode enabled but **no UDP stream**, the lamp remained statically lit.

## Prerequisites

1. The lamp is already on an **independent Matter Fabric** ([pairing instructions](02_PAIR_EN.md)). This experiment is not a substitute for initial pairing.
2. Save the initial lamp state and a private Matter.js `/data` backup; have a recovery plan.
3. The test used locally patched image `1.5.5-direct-color-music-v1`. **That image is not in this GitHub repository.** Do not blindly replace the working `1.5.5-direct-v1` image or alter persistence.
4. Ubuntu can send UDP to the lamp's destination port `4048`. Keep Matter WebSocket off the public internet.

## 1. Enable Color music over Matter.js

Verified Matter contract: **endpoint 1**, vendor cluster `0x132FFC06`.

| Command | ID | Payload | TLV |
|---|---|---|---|
| `SetEnable` | `0x132F0001` | `{enable: true}` | `15 29 00 18` |
| `SetEnable` | `0x132F0001` | `{enable: false}` | `15 28 00 18` |
| `SetAnimation` | `0x132F0002` | `{animationId: uint8}` | `15 24 00 <id> 18` |

Working order: **`SetEnable(true)` → `SetAnimation(0)`**. The lamp advertised IDs `[0,1,2]`, but **only ID 0 was tested on hardware**. A separate readback confirmed:

| Attribute | Value |
|---|---|
| `OnOff` | `true` |
| `enable` | `1` |
| Vendor category | `3` — `Color music` |

~~~mermaid
sequenceDiagram
    participant M as Matter.js
    participant L as Lamp
    participant U as Ubuntu
    M->>L: SetEnable(true)
    M->>L: SetAnimation(0)
    L-->>M: OnOff=true; enable=1; category=3
    Note over L: Static until UDP frames arrive
    U->>L: UDP/4048 replay
    Note over L: Visible pulsing
~~~

**Important:** the published `tools/matter_lamp/matter-lamp-client.mjs` CLI does **not** yet offer a Color music command. `set_scene` is a different cluster and cannot substitute for this function.

## 2. Replay UDP/4048 frames

The observed UDP **payload is 490 bytes** per frame:

~~~text
offset 0..9     10 B    header = 41 00 a9 01 00 00 00 00 01 e0
offset 10..489  480 B   120 x unsigned uint32 (big-endian)
total           490 B   destination UDP/4048
~~~

~~~mermaid
flowchart LR
    P["UDP payload<br/>490 bytes"] --> H["Header<br/>10 bytes"]
    P --> B["Body<br/>480 bytes"]
    B --> F["120 x uint32 BE<br/>frequency mapping unknown"]
~~~

The original stream used observed source port `44207`. This is **not established as a required source port**. Successful replay from Ubuntu demonstrates that the Station's original source IP was unnecessary **in the tested configuration**.

| Hardware trial | Outcome |
|---|---|
| 1 original packet | PASS |
| 98 packets over ~2 seconds | PASS |
| 245 packets over ~5 seconds | PASS, visible pulsing |
| Station unplugged, independent Matter enable + 245/245 packets | PASS, visible pulsing |

The replay averaged **about 49 packets/s**; this is not necessarily the rate of **distinct** spectrum frames.

## 3. Repeat with the Station offline

In the separate trial, the Station was physically unplugged and SSH unavailable. Ubuntu, Matter.js and the lamp remained reachable. `SetEnable`, `SetAnimation(0)`, and the 245-frame UDP replay still succeeded with observed pulsing.

**Conclusion:** for an **already paired lamp** in this tested configuration, the Station is not needed as a Matter relay or UDP source. This does **not** prove that initial pairing works without the Station.

## 4. Restore the original state

1. `SetEnable(false)` and read back `enable=0`.
2. Restore **your own** original category, color, level/temperature and `OnOff`.
3. Check Matter.js `healthy`, restart count `0`, peer reachable, `/data` unchanged.
4. If unplugged, start the Station and verify stock `maind --platformd` and closed TCP/8765.

**Reported final state:** `OnOff=false`, `Color` category, hue/saturation `52/244`; Station returned normally, TCP/8765 closed. `52/244` was **one test's baseline, not a universal restore target**.

If the lamp stays static, read back mode/category and check that UDP frames reach the device. Do not blindly repeat commissioning or vendor commands.

## What remains unknown

| Capability | Status |
|---|---|
| Independent Matter enable and state readback | **Hardware PASS** |
| Original UDP replay and visible pulsing | **Hardware PASS** |
| Playback with the Station offline | **Hardware PASS** |
| 9/9 offline checks, JS/Python syntax, JSON validation | **PASS in the supplied report** |
| Source scripts published in Git | **Not yet** |
| Synthetic live FFT → UDP tested on lamp | **NOT TESTED** |
| 120-band frequency mapping, gain/smoothing | **UNKNOWN** |
| Animation IDs 1 and 2 | **NOT TESTED** |

Local research files: `color_music_matter_client.mjs`, `replay_udp4048.py`, `patch-color-music.mjs` and `audio_to_udp4048_prototype.py`. The FFT prototype passed offline tests with **250/2000/8000 Hz** sine signals, but **no synthetic UDP frames were sent to the lamp**. The private report, `summary.json`, PCAPs and Matter `/data` are not published. As the source scripts are not in GitHub, **no executable replay command is claimed here**.

[Back to the project map](00_START_EN.md) · [Troubleshooting](04_RECOVERY_EN.md)
