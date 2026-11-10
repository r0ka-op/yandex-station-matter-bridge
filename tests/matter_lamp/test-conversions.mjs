import assert from "node:assert/strict";
import { describeSceneState, kelvinToMireds, levelToPercent, MatterLamp, percentToLevel, percentToMatterByte, sceneToMode } from "../../tools/matter_lamp/matter-lamp-client.mjs";

assert.equal(percentToLevel(50), 127);
assert.equal(percentToLevel(100), 254);
assert.equal(levelToPercent(254), 100);
assert.equal(percentToMatterByte(50, "hue"), 127);
assert.equal(kelvinToMireds(4000, 154, 370), 250);
assert.equal(sceneToMode("rainbow"), 13);
assert.equal(sceneToMode("fire"), 4);
assert.equal(sceneToMode("northern_lights"), 6);
assert.equal(sceneToMode("lava_lamp"), 1);
assert.throws(() => percentToLevel(0));
assert.throws(() => percentToMatterByte(101, "saturation"));
assert.throws(() => kelvinToMireds(1000, 154, 370));
assert.throws(() => sceneToMode("unknown"));
assert.deepEqual(
  describeSceneState({ currentMode: 0, lastSelectedSceneId: 4, vendorMode: 2, onOff: true }),
  {
    currentMode: 0,
    lastSelectedSceneId: 4,
    lastSelectedSceneName: "fire",
    category: { id: 2, name: "scene" },
    onOff: true,
    active: true,
    activeSceneId: 4,
    activeSceneName: "fire",
    sceneDeterminationAvailable: true,
  },
);
const inactiveScene = describeSceneState({ currentMode: 0, lastSelectedSceneId: 4, vendorMode: 1, onOff: false });
assert.equal(inactiveScene.active, false);
assert.equal(inactiveScene.activeSceneId, null);
assert.equal(inactiveScene.activeSceneName, null);
assert.equal(inactiveScene.lastSelectedSceneName, "fire");

const values = {
  "1/80/0": "",
  "1/80/1": 0,
  "1/80/3": 6,
  "1/321911820/1": 2,
  "1/6/0": true,
};
const fakeClient = {
  async command(command, args) {
    assert.equal(command, "read");
    const path = args.attribute_paths[0];
    return { attributes: { [path]: values[path] } };
  },
};
const fakeLamp = new MatterLamp(fakeClient, 2);
const scenes = await fakeLamp.getScenes();
assert.equal(scenes.deviceListAvailable, false);
assert.equal(scenes.supportedModesRaw, "");
assert.deepEqual(scenes.hardwareVerifiedModes.map(item => item.id), [1, 4, 6, 13]);
const liveScene = await fakeLamp.getScene();
assert.equal(liveScene.activeSceneName, "northern_lights");
assert.equal(liveScene.currentMode, 0);
console.log("matter lamp conversion tests PASS");
