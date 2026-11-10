import { readFileSync, writeFileSync } from "node:fs";

const path = "/app/node_modules/@matter-server/ws-controller/dist/esm/controller/ControllerCommandHandler.js";
let source = readFileSync(path, "utf8");

const oldBlock = `    const clusterName = clusterEntry.model.propertyName;
    const command = camelize(commandName);
    const endpoint = this.#clusterEndpoint(nodeId, endpointId, clusterName);
    const commands = endpoint.commands[clusterName];
    const model = clusterEntry.commands[command.toLowerCase()];
    if (!model || !commands[command]) {
      throw ServerError.invalidArguments(\`Command "\${command}" does not exist on cluster "\${clusterName}"\`);
    }`;

const newBlock = `    const clusterName = clusterEntry.model.propertyName;
    const command = camelize(commandName);
    const model = clusterEntry.commands[command.toLowerCase()];
    const directNodeId = process.env.YNDX00560_DIRECT_INVOKE_NODE_ID;
    const directAllowlist = new Map([
      [6, new Set(["off", "on"])],
      [8, new Set(["moveToLevel"])],
      [80, new Set(["changeToMode"])],
      [768, new Set(["moveToHueAndSaturation", "moveToColorTemperature"])],
    ]);
    const directAllowed = directNodeId !== undefined && String(nodeId) === directNodeId && endpointId === 1 && directAllowlist.get(Number(clusterId))?.has(command) === true;
    if (directAllowed && Number(clusterId) === 80) {
      // These are TColorCapability.EColorScene values passed unchanged by
      // maind to ModeSelect.ChangeToMode. Keep the list closed.
      const allowedSceneModes = new Set([1, 4, 6, 13]);
      const keys = isObject(commandData) ? Object.keys(commandData) : [];
      if (keys.length !== 1 || keys[0] !== "newMode" || !Number.isInteger(commandData.newMode) || !allowedSceneModes.has(commandData.newMode)) {
        throw ServerError.invalidArguments("ModeSelect direct invoke only permits a verified named scene mode");
      }
    }
    if (!directAllowed) {
      const endpoint = this.#clusterEndpoint(nodeId, endpointId, clusterName);
      const commands = endpoint.commands[clusterName];
      if (!model || !commands[command]) {
        throw ServerError.invalidArguments(\`Command "\${command}" does not exist on cluster "\${clusterName}"\`);
      }
    } else if (!model) {
      throw ServerError.invalidArguments(\`Command "\${command}" does not exist on cluster "\${clusterName}"\`);
    }`;

if (!source.includes(oldBlock)) throw new Error("expected ControllerCommandHandler block not found");
if (source.includes("YNDX00560_DIRECT_INVOKE_NODE_ID")) throw new Error("patch already applied");
source = source.replace(oldBlock, newBlock);
writeFileSync(path, source);
