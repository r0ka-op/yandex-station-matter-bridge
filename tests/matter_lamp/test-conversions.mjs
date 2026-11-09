import assert from "node:assert/strict";
import { kelvinToMireds, levelToPercent, percentToLevel, percentToMatterByte } from "../../tools/matter_lamp/matter-lamp-client.mjs";

assert.equal(percentToLevel(50), 127);
assert.equal(percentToLevel(100), 254);
assert.equal(levelToPercent(254), 100);
assert.equal(percentToMatterByte(50, "hue"), 127);
assert.equal(kelvinToMireds(4000, 154, 370), 250);
assert.throws(() => percentToLevel(0));
assert.throws(() => percentToMatterByte(101, "saturation"));
assert.throws(() => kelvinToMireds(1000, 154, 370));
console.log("matter lamp conversion tests PASS");
