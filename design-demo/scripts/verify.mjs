import { spawnSync } from "node:child_process";

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: new URL("../", import.meta.url),
    stdio: "inherit",
    shell: false
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

run(process.execPath, ["--test", "--test-reporter=spec"]);
run(process.execPath, ["scripts/browser-smoke.mjs"]);
run(process.execPath, ["scripts/screenshots.mjs"]);

process.stdout.write("Changliao HTML Demo verification: PASS\n");
