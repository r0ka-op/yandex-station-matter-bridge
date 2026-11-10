# 01 · Prepare your setup

[← Start](00_START_EN.md) · [Next: Pairing →](02_PAIR_EN.md) · [Русский](01_SETUP_RU.md)

**Goal:** Matter.js is healthy, accessible from your workstation, the LAN is ready, and private persistence has been backed up. **No changes** to the Station or lamp yet.

```mermaid
flowchart LR
    A["Ubuntu + Docker"] --> B["Host network<br/>IPv6 and mDNS"] --> C["Matter.js healthy"] --> D["Private /data backup"] --> E(["Ready to pair"])
```

## Step 1. Check out the matching source

**Where:** Git terminal on the host used for the build.

```bash
git clone https://github.com/r0ka-op/yandex-station-matter-bridge.git
cd yandex-station-matter-bridge
git fetch origin
# Until the documentation PR merges:
git switch docs/bilingual-reproduction-runbook
```

**Check:** `deploy/matter-server-direct/Dockerfile`, `deploy/matter-server/docker-compose.ubuntu.yml`, and `tools/matter_lamp/matter-lamp-client.mjs` are present. Use `main` after the documentation and scene-control PRs merge.

## Step 2. Inspect the network (read-only)

**Where:** Ubuntu.

```bash
ip -br address
ip -6 route
LAN_IF="REPLACE_WITH_LAN_INTERFACE"
ip maddr show dev "$LAN_IF"
ss -lntup
avahi-browse -rt _matterc._udp
```

| Expected | If not |
|---|---|
| LAN interface up; IPv6 link-local works | Fix network before pairing |
| Multicast/mDNS UDP/5353 and Matter UDP/5540 allowed | Inspect Wi-Fi client isolation and firewall |
| No `_matterc._udp` advertisement yet | **Normal:** window is not open yet |

Do not factory reset the lamp to fix multicast.

## Step 3. Build Matter.js

**Where:** Ubuntu from source root, with Docker Engine and Compose installed.

```bash
docker build -t yandex-matterjs-server:1.5.5-direct-v1 deploy/matter-server-direct
mkdir -p "$HOME/matter-lab/matter-data"
cp deploy/matter-server/docker-compose.ubuntu.yml "$HOME/matter-lab/compose.yml"
```

Edit the **private** `$HOME/matter-lab/compose.yml`:

| Setting | Value | Reason |
|---|---|---|
| `PRIMARY_INTERFACE` | Real LAN interface | Device reachability |
| `LISTEN_ADDRESS` | `127.0.0.1,<LAN_INTERFACE>` | Trusted network only |
| `STORAGE_PATH`/volume | `/data`, `./matter-data:/data` | Persistent identity |
| `ENABLE_TEST_NET_DCL` | `"true"` | Required in tested attestation flow |
| `DISABLE_AUTO_SUBSCRIPTION` | `"true"` | Avoids observed bootstrap failure |
| `YNDX00560_DIRECT_INVOKE_NODE_ID` | **REMOVE** before pairing | Sample `2` is not your Node ID |

Do not disable attestation or commit the private compose file.

```bash
cd "$HOME/matter-lab"
docker compose up -d
docker compose ps
docker inspect --format '{{.State.Health.Status}} {{.RestartCount}}' matterjs-server
```

**Expected:** `healthy`, restart count `0`. Otherwise inspect `docker compose logs --tail=100 matter-server` and **stop before commissioning**.

## Step 4. Back up persistence with the server stopped

```bash
mkdir -p "$HOME/matter-private-backups"
chmod 700 "$HOME/matter-private-backups"
cd "$HOME/matter-lab"
docker compose stop matter-server
umask 077
tar -C "$HOME/matter-lab" -czf "$HOME/matter-private-backups/before-ecm.tgz" matter-data
chmod 600 "$HOME/matter-private-backups/before-ecm.tgz"
docker compose start matter-server
```

**Expected:** healthy again, private backup file present. It contains sensitive Fabric material; **never publish it**.

## Step 5. Read-only Station readiness check

**Where:** Windows PowerShell 7 from the repo root. Root/SSH must already work.

```powershell
$StationAlias = 'REPLACE_WITH_SSH_ALIAS'
$PrivateDir = 'REPLACE_WITH_PRIVATE_ABSOLUTE_PATH'
& .\scripts\check_maind_http_station_readiness.ps1 -SshAlias $StationAlias -OutputPath (Join-Path $PrivateDir 'station-readiness.json')
```

**PASS:** one stock `maind --platformd`, expected hashes for `maind` and `quasar_launcher2`, TCP/8765 closed, no unresolved experiment. If hash or firmware differs, **stop** rather than bypassing the guards.

**Before continuing, verify:**

- [ ] Matter.js healthy, permanent `/data`.
- [ ] IPv6/mDNS/Matter network ready.
- [ ] Private backup stored **outside Git**.
- [ ] Station readiness PASS; TCP/8765 closed.

**Ready? [Continue to one-time pairing →](02_PAIR_EN.md)**