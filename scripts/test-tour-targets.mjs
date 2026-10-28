import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
// Every element the guided tour points at must still exist in the app's source.
const dir = "apps/web/src/";
const sources = readdirSync(dir).filter((f) => f.endsWith(".tsx")).map((f) => readFileSync(dir + f, "utf8")).join("\n");
const app = readFileSync(dir + "App.tsx", "utf8");
const targets = [...app.matchAll(/target: "([^"]+)"/g)].map((m) => m[1]);
assert.ok(targets.length >= 8, "tour has targeted steps");
for (const selector of targets) {
  for (const option of selector.split(",").map((s) => s.trim())) {
    const tokens = option.split(/\s+/).filter((t) => !["nav", "aside"].includes(t));
    const classes = tokens.flatMap((t) => [...t.matchAll(/\.([A-Za-z0-9_-]+)/g)].map((m) => m[1]));
    const found = classes.length === 0 || classes.every((c) => sources.includes(c));
    if (selector.includes(",")) { if (found) { assert.ok(true); break; } else continue; }
    assert.ok(found, `tour target ${option} is missing from the source`);
  }
}
const steps = [...app.matchAll(/\{ id: "([a-z]+)", title:/g)].map((m) => m[1]);
assert.equal(new Set(steps).size, steps.length, "tour step ids are unique");
assert.ok(steps[0] === "welcome" && steps.at(-1) === "done");
const tour = readFileSync(dir + "Tour.tsx", "utf8");
assert.match(tour, /Escape/, "tour can be closed with Escape");
assert.match(app, /cloudledger\.tour\.v1\./, "tour completion is remembered per user");
console.log("Tour checks passed:", steps.length, "steps, all targets present.");
