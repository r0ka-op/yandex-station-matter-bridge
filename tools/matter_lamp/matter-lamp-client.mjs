#!/usr/bin/env node
import { randomUUID } from "node:crypto";

export const PATH = Object.freeze({
  onOff: "1/6/0",
  currentLevel: "1/8/0",
  currentHue: "1/768/0",
  currentSaturation: "1/768/1",
  currentX: "1/768/3",
  currentY: "1/768/4",
  colorTemperatureMireds: "1/768/7",
  colorMode: "1/768/8",
  enhancedColorMode: "1/768/16385",
  supportedModes: "1/80/0",
  currentMode: "1/80/1",
  lastSelectedSceneMode: "1/80/3",
  vendorMode: "1/321911820/1",
  colorCapabilities: "1/768/16394",
  physicalMinMireds: "1/768/16395",
  physicalMaxMireds: "1/768/16396",
});

const CLUSTER = Object.freeze({ onOff: 6, level: 8, modeSelect: 80, color: 768 });
const SCENE = Object.freeze({
  lava_lamp: 1,
  fire: 4,
  northern_lights: 6,
  rainbow: 13,
});
const SCENE_VERIFICATION = Object.freeze({
  lava_lamp: "hardware-invoke-readback-visual",
  fire: "hardware-invoke-readback-visual",
  northern_lights: "hardware-invoke-readback-visual",
  rainbow: "hardware-invoke-readback",
});
const VENDOR_MODE = Object.freeze({ 0: "none", 1: "color", 2: "scene", 3: "color_music" });
const DEFAULT_URI = "ws://127.0.0.1:5580/ws";
const DEFAULT_NODE = 2;

export function percentToLevel(percent) {
  if (!Number.isFinite(percent) || percent < 1 || percent > 100) throw new Error("brightness must be 1..100 percent");
  return Math.max(1, Math.min(254, Math.round(percent * 254 / 100)));
}

export function levelToPercent(level) {
  return Math.round(Number(level) * 1000 / 254) / 10;
}

export function kelvinToMireds(kelvin, minMireds, maxMireds) {
  if (!Number.isFinite(kelvin) || kelvin <= 0) throw new Error("kelvin must be positive");
  const mireds = Math.round(1_000_000 / kelvin);
  if (mireds < minMireds || mireds > maxMireds) {
    throw new Error(`color temperature must be ${Math.ceil(1_000_000 / maxMireds)}..${Math.floor(1_000_000 / minMireds)} K`);
  }
  return mireds;
}

export function percentToMatterByte(value, name) {
  if (!Number.isFinite(value) || value < 0 || value > 100) throw new Error(`${name} must be 0..100 percent`);
  return Math.round(value * 254 / 100);
}

export function sceneToMode(name) {
  const mode = SCENE[name];
  if (mode === undefined) throw new Error(`unsupported or unverified scene: ${name}`);
  return mode;
}

export function describeSceneState({ currentMode, lastSelectedSceneId, vendorMode, onOff }) {
  const lastSelectedSceneName = Object.entries(SCENE).find(([, mode]) => mode === lastSelectedSceneId)?.[0] ?? null;
  const active = onOff === true && vendorMode === 2;
  return {
    currentMode,
    lastSelectedSceneId,
    lastSelectedSceneName,
    category: { id: vendorMode, name: VENDOR_MODE[vendorMode] ?? "unknown" },
    onOff,
    active,
    activeSceneId: active ? lastSelectedSceneId : null,
    activeSceneName: active ? lastSelectedSceneName : null,
    sceneDeterminationAvailable: Number.isInteger(lastSelectedSceneId) && lastSelectedSceneName !== null,
  };
}

class MatterWsClient {
  constructor(uri, timeoutMs = 12_000) {
    this.uri = uri;
    this.timeoutMs = timeoutMs;
    this.ws = undefined;
    this.pending = new Map();
  }

  async connect() {
    const ws = new WebSocket(this.uri);
    this.ws = ws;
    ws.onmessage = event => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      if (!message.message_id || !this.pending.has(message.message_id)) return;
      const pending = this.pending.get(message.message_id);
      this.pending.delete(message.message_id);
      clearTimeout(pending.timer);
      if (message.error_code !== undefined && message.error_code !== null) {
        pending.reject(Object.assign(new Error(`Matter.js ${pending.command} failed`), {
          diagnostic: {
            error_code: message.error_code,
            reason: message.reason ?? null,
            status: message.status ?? null,
            cluster_status: message.cluster_status ?? null,
          },
        }));
      } else {
        pending.resolve(message.result);
      }
    };
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("WebSocket connect timeout")), this.timeoutMs);
      ws.onopen = () => { clearTimeout(timer); resolve(); };
      ws.onerror = () => { clearTimeout(timer); reject(new Error("WebSocket connection failed")); };
    });
  }

  command(command, args, timeoutMs = this.timeoutMs) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) throw new Error("WebSocket is not open");
    return new Promise((resolve, reject) => {
      const message_id = `lamp-${randomUUID()}`;
      const timer = setTimeout(() => {
        this.pending.delete(message_id);
        reject(Object.assign(new Error(`${command} response timeout; result is ambiguous`), {
          diagnostic: { error_code: null, reason: "local-timeout-ambiguous" },
        }));
      }, timeoutMs);
      this.pending.set(message_id, { resolve, reject, timer, command });
      this.ws.send(JSON.stringify({ message_id, command, args }));
    });
  }

  close() {
    if (this.ws) this.ws.close();
  }
}

export class MatterLamp {
  constructor(client, nodeId = DEFAULT_NODE) {
    this.client = client;
    this.nodeId = nodeId;
  }

  async readPath(path) {
    let report;
    try {
      report = await this.client.command("read", {
        node_id: this.nodeId,
        attribute_paths: [path],
        fabric_filtered: true,
      });
    } catch (error) {
      error.message = `read ${path} failed: ${error.message}`;
      throw error;
    }
    if (report?.attribute_status?.[path]) throw new Error(`Matter status for ${path}: ${JSON.stringify(report.attribute_status[path])}`);
    if (!Object.hasOwn(report?.attributes ?? {}, path)) throw new Error(`attribute ${path} absent from device response`);
    return report.attributes[path];
  }

  async getState() {
    const state = {};
    // The lamp advertises MaxPathsPerInvoke=1 and is unreliable with concurrent exchanges.
    for (const [name, path] of Object.entries(PATH)) state[name] = await this.readPath(path);
    state.brightnessPercent = levelToPercent(state.currentLevel);
    state.colorTemperatureKelvin = Math.round(1_000_000 / state.colorTemperatureMireds);
    return state;
  }

  async invoke(cluster_id, command_name, payload = {}) {
    return this.client.command("device_command", {
      node_id: this.nodeId,
      endpoint_id: 1,
      cluster_id,
      command_name,
      payload,
      response_type: null,
      interaction_timeout_ms: 8_000,
    }, 12_000);
  }

  async turnOn() {
    await this.invoke(CLUSTER.onOff, "on");
    await delay(500);
    return { requested: true, readback: await this.readPath(PATH.onOff) };
  }

  async turnOff() {
    await this.invoke(CLUSTER.onOff, "off");
    await delay(500);
    return { requested: false, readback: await this.readPath(PATH.onOff) };
  }

  async setBrightness(percent) {
    const level = percentToLevel(percent);
    await this.invoke(CLUSTER.level, "moveToLevel", {
      level,
      transitionTime: 5,
      optionsMask: {},
      optionsOverride: {},
    });
    await delay(3_000);
    const readback = await this.readPath(PATH.currentLevel);
    return { requestedPercent: percent, requestedLevel: level, readback, readbackPercent: levelToPercent(readback) };
  }

  async setColor(huePercent, saturationPercent) {
    const hue = percentToMatterByte(huePercent, "hue");
    const saturation = percentToMatterByte(saturationPercent, "saturation");
    await this.invoke(CLUSTER.color, "moveToHueAndSaturation", {
      hue,
      saturation,
      transitionTime: 5,
      optionsMask: {},
      optionsOverride: {},
    });
    await delay(1_200);
    return {
      requested: { hue, saturation },
      readback: {
        hue: await this.readPath(PATH.currentHue),
        saturation: await this.readPath(PATH.currentSaturation),
        colorMode: await this.readPath(PATH.colorMode),
      },
    };
  }

  async setColorTemperature(kelvin) {
    const min = await this.readPath(PATH.physicalMinMireds);
    const max = await this.readPath(PATH.physicalMaxMireds);
    const mireds = kelvinToMireds(kelvin, min, max);
    await this.invoke(CLUSTER.color, "moveToColorTemperature", {
      colorTemperatureMireds: mireds,
      transitionTime: 5,
      optionsMask: {},
      optionsOverride: {},
    });
    await delay(1_200);
    return {
      requestedKelvin: kelvin,
      requestedMireds: mireds,
      readbackMireds: await this.readPath(PATH.colorTemperatureMireds),
      colorMode: await this.readPath(PATH.colorMode),
    };
  }

  async setScene(name) {
    const newMode = sceneToMode(name);
    await this.invoke(CLUSTER.modeSelect, "changeToMode", { newMode });
    await delay(1_200);
    const readback = {
      currentMode: await this.readPath(PATH.currentMode),
      lastSelectedSceneId: await this.readPath(PATH.lastSelectedSceneMode),
      vendorMode: await this.readPath(PATH.vendorMode),
      onOff: await this.readPath(PATH.onOff),
    };
    if (readback.lastSelectedSceneId !== newMode || readback.vendorMode !== 2 || readback.onOff !== true) {
      throw new Error(`scene readback mismatch: lastSelected=${readback.lastSelectedSceneId} vendorMode=${readback.vendorMode} onOff=${readback.onOff}`);
    }
    return {
      requested: name,
      readback,
    };
  }

  async getScene() {
    const currentMode = await this.readPath(PATH.currentMode);
    const lastSelectedSceneId = await this.readPath(PATH.lastSelectedSceneMode);
    const vendorMode = await this.readPath(PATH.vendorMode);
    const onOff = await this.readPath(PATH.onOff);
    return describeSceneState({ currentMode, lastSelectedSceneId, vendorMode, onOff });
  }

  async getScenes() {
    const supportedModesRaw = await this.readPath(PATH.supportedModes);
    const deviceListAvailable = Array.isArray(supportedModesRaw);
    return {
      deviceListAvailable,
      supportedModesRaw,
      limitation: deviceListAvailable
        ? null
        : "YNDX-00560 returns a non-list value for ModeSelect.SupportedModes; the complete device-advertised list is unavailable",
      hardwareVerifiedModes: Object.entries(SCENE).map(([name, id]) => ({
        id,
        name,
        verification: SCENE_VERIFICATION[name],
      })),
      enumOnlyModesIncluded: false,
    };
  }

  async getCapabilities() {
    const paths = {
      onOffCommands: "1/6/65529",
      levelCommands: "1/8/65529",
      colorCommands: "1/768/65529",
      colorFeatureMap: "1/768/65532",
      colorCapabilities: PATH.colorCapabilities,
      minMireds: PATH.physicalMinMireds,
      maxMireds: PATH.physicalMaxMireds,
    };
    const capabilities = {};
    for (const [name, path] of Object.entries(paths)) capabilities[name] = await this.readPath(path);
    return capabilities;
  }

  async getHealth() {
    const server = await this.client.command("server_info", {});
    const nodes = await this.client.command("get_nodes", { only_available: false });
    const node = nodes.find(item => String(item.node_id) === String(this.nodeId));
    const started = performance.now();
    const onOff = await this.readPath(PATH.onOff);
    return {
      server,
      nodePresent: Boolean(node),
      nodeAvailable: node?.available ?? null,
      subscriptionMode: "disabled-polling",
      directRead: true,
      directReadLatencyMs: Math.round(performance.now() - started),
      onOff,
    };
  }
}

function delay(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

function parseArgs(argv) {
  const opts = { uri: DEFAULT_URI, node: DEFAULT_NODE };
  const positional = [];
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    if (value === "--uri") opts.uri = argv[++index];
    else if (value === "--node") opts.node = Number(argv[++index]);
    else positional.push(value);
  }
  return { opts, positional };
}

async function cli() {
  const { opts, positional } = parseArgs(process.argv.slice(2));
  const action = positional[0] ?? "get_state";
  const client = new MatterWsClient(opts.uri);
  await client.connect();
  const lamp = new MatterLamp(client, opts.node);
  try {
    let result;
    if (action === "get_state") result = await lamp.getState();
    else if (action === "get_capabilities") result = await lamp.getCapabilities();
    else if (action === "get_health") result = await lamp.getHealth();
    else if (action === "turn_on") result = await lamp.turnOn();
    else if (action === "turn_off") result = await lamp.turnOff();
    else if (action === "set_brightness") result = await lamp.setBrightness(Number(positional[1]));
    else if (action === "set_color") result = await lamp.setColor(Number(positional[1]), Number(positional[2]));
    else if (action === "set_color_temperature") result = await lamp.setColorTemperature(Number(positional[1]));
    else if (action === "set_scene") result = await lamp.setScene(String(positional[1] ?? ""));
    else if (action === "get_scene") result = await lamp.getScene();
    else if (action === "get_scenes") result = await lamp.getScenes();
    else throw new Error(`unknown action: ${action}`);
    console.log(JSON.stringify({ ok: true, action, nodeId: opts.node, result }, null, 2));
  } catch (error) {
    console.error(JSON.stringify({ ok: false, action, error: error.message, diagnostic: error.diagnostic ?? null }));
    process.exitCode = 1;
  } finally {
    client.close();
  }
}

if (process.argv[1] && import.meta.url === new URL(`file:///${process.argv[1].replaceAll("\\", "/")}`).href) {
  await cli();
}
