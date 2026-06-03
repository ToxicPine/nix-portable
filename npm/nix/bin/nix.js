#!/usr/bin/env node

const { spawn } = require("node:child_process");
const path = require("node:path");

const packages = {
  "linux:x64": "@cardelli/nix-linux-x64",
  "linux:arm64": "@cardelli/nix-linux-arm64",
  "darwin:x64": "@cardelli/nix-darwin-x64",
  "darwin:arm64": "@cardelli/nix-darwin-arm64",
};

const key = `${process.platform}:${process.arch}`;
const platformPackage = packages[key];

if (!platformPackage) {
  console.error(
    "@cardelli/nix supports linux x64/arm64 and darwin x64/arm64. On Windows use WSL."
  );
  process.exit(1);
}

let portable;
try {
  portable = require.resolve(`${platformPackage}/bin/nix-portable`);
} catch (error) {
  console.error(`The optional package ${platformPackage} was not installed.`);
  console.error(`Reinstall @cardelli/nix on ${process.platform} ${process.arch}.`);
  process.exit(1);
}

const invokedAs = path.basename(process.argv[1] || "nix");
const args = process.argv.slice(2);
const portableArgs = invokedAs.startsWith("nix-portable")
  ? args
  : [invokedAs, ...args];

const child = spawn(portable, portableArgs, { stdio: "inherit" });

child.on("error", (error) => {
  console.error(error.message);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
