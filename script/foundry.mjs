#!/usr/bin/env node
// Runs forge / cast / anvil from the pinned @foundry-rs npm packages and propagates the exit code.
// The packages' own bin.mjs launchers always exit 0, which would let a failing `forge test` pass in CI.
//
//   node script/foundry.mjs forge test -vv
//   node script/foundry.mjs --path anvil        # print the native binary path (for shell scripts)
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";

const argv = process.argv.slice(2);
const printPath = argv[0] === "--path";
if (printPath) argv.shift();
const [tool, ...args] = argv;
if (!["forge", "cast", "anvil", "chisel"].includes(tool)) {
  console.error("usage: node script/foundry.mjs [--path] <forge|cast|anvil|chisel> [args...]");
  process.exit(2);
}

const os = { linux: "linux", darwin: "darwin", win32: "win32" }[process.platform];
const arch = { x64: "amd64", arm64: "arm64" }[process.arch];
if (!os || !arch) {
  console.error(`unsupported platform ${process.platform}/${process.arch}`);
  process.exit(1);
}

const require = createRequire(import.meta.url);
let bin;
try {
  const dir = path.dirname(require.resolve(`@foundry-rs/${tool}-${os}-${arch}/package.json`));
  bin = path.join(dir, "bin", tool + (os === "win32" ? ".exe" : ""));
} catch {
  console.error(`@foundry-rs/${tool}-${os}-${arch} is not installed; run npm install in the repo root`);
  process.exit(1);
}

if (printPath) {
  console.log(bin);
  process.exit(0);
}
const r = spawnSync(bin, args, { stdio: "inherit" });
if (r.error) {
  console.error(r.error.message);
  process.exit(1);
}
process.exit(r.status ?? 1);
