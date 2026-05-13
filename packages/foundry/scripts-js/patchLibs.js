/* eslint-disable no-console */
// Patches pragma declarations in vendored submodules so they can co-compile
// with our OZ V5 (^0.8.20) code. We don't fork the libraries — instead we
// relax their pinned pragmas to `^0.8.x` post-install. Idempotent.

import { readFileSync, writeFileSync } from "fs";
import { execSync } from "child_process";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const libRoot = join(__dirname, "..", "lib");

const patches = [
  { dir: "morpho-blue/src",            from: "pragma solidity 0.8.19;",  to: "pragma solidity ^0.8.19;"  },
  { dir: "Yearn-ERC4626-Router/src",   from: "pragma solidity 0.8.18;",  to: "pragma solidity ^0.8.18;"  },
];

let touched = 0;
for (const { dir, from, to } of patches) {
  const root = join(libRoot, dir);
  let files;
  try {
    files = execSync(`grep -rl "${from}" "${root}"`, { encoding: "utf8" })
      .split("\n").filter(Boolean);
  } catch {
    // grep exits 1 when nothing matches — already patched, or lib missing.
    continue;
  }
  for (const f of files) {
    const src = readFileSync(f, "utf8");
    if (!src.includes(from)) continue;
    writeFileSync(f, src.replace(from, to));
    touched++;
  }
}

console.log(touched === 0 ? "patchLibs: nothing to patch" : `patchLibs: relaxed pragma in ${touched} file(s)`);
