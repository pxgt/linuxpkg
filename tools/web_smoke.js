// Smoke test of the browser build (web/web.js) under Node: it must produce the
// same package bytes as the command line, and describe them with the same JSON.
//
// Usage: node tools/web_smoke.js <web.js> <example dir> <dir with CLI packages> <dir with CLI inspect --json files>
// The CLI files are named after the package, with ".json" appended for the JSON.
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const [webJs, exampleDir, cliDir, jsonDir] = process.argv.slice(2);
require(path.resolve(webJs));
const { lp_inspect, lp_verify, lp_build } = globalThis;
assert.strictEqual(typeof lp_build, "function", "web.js must export lp_build");

const configText = fs.readFileSync(path.join(exampleDir, "linuxpkg.json"), "utf8");
const config = JSON.parse(configText);
const sources = new Set();
for (const item of config.contents || []) {
  if (item.src && (!item.type || item.type === "file" || item.type === "config")) sources.add(item.src);
}
for (const script of Object.values(config.scripts || {})) sources.add(script);
const files = {};
for (const src of sources) {
  files[src] = fs.readFileSync(path.join(exampleDir, src)).toString("base64");
}

const built = JSON.parse(lp_build(configText, JSON.stringify(files), "all", "", 0));
assert.ok(!built.error, built.error);
assert.deepStrictEqual(built.packages.map((p) => p.format), ["deb", "rpm", "arch", "apk"]);

let checked = 0;
for (const pkg of built.packages) {
  const bytes = Buffer.from(pkg.data, "base64");
  const cli = fs.readFileSync(path.join(cliDir, pkg.name));
  assert.ok(bytes.equals(cli), `${pkg.name}: the browser build differs from the command line`);
  const info = JSON.parse(lp_inspect(pkg.name, pkg.data));
  assert.ok(!info.error, info.error);
  assert.strictEqual(info.kind, pkg.format);
  assert.deepStrictEqual(info.problems, [], `${pkg.name}: problems`);
  const cliReport = JSON.parse(fs.readFileSync(path.join(jsonDir, pkg.name + ".json"), "utf8"));
  assert.deepStrictEqual(info.report, cliReport, `${pkg.name}: inspect differs from the command line`);
  const verified = JSON.parse(lp_verify(pkg.name, pkg.data, ""));
  assert.deepStrictEqual(verified.problems, []);
  assert.ok(verified.checked > 0);
  // A damaged copy must be reported, not accepted.
  const damaged = Buffer.from(bytes);
  damaged[damaged.length - 20] ^= 0xff;
  const bad = JSON.parse(lp_verify(pkg.name, damaged.toString("base64"), ""));
  assert.ok(bad.error || bad.problems.length > 0, `${pkg.name}: damage not noticed`);
  checked += 1;
}
// Things that are not packages, bad configurations and unknown options give errors, never exceptions.
assert.ok(JSON.parse(lp_inspect("x.deb", Buffer.from("hello").toString("base64"))).error);
assert.ok(JSON.parse(lp_inspect("x.deb", "###")).error);
assert.ok(JSON.parse(lp_build("{}", "{}", "all", "", 0)).error);
assert.ok(JSON.parse(lp_build(configText, "{}", "all", "", 0)).error);
assert.ok(JSON.parse(lp_build(configText, JSON.stringify(files), "all", "bzip2", 0)).error);
console.log(`web smoke test: ${checked} packages are byte-identical to the command line and inspect the same`);
