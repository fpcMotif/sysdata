import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { commandFor, config, execute, main, root } from "./run.mjs";

let passed = 0;
async function test(name, check) {
  await check();
  passed += 1;
  console.info("PASS " + name);
}

await test("commands stay in this project and reference existing directories", () => {
  assert(Object.keys(config.commands).length > 0);
  for (const name of Object.keys(config.commands)) {
    const operation = commandFor(name, config.commands[name].scoped ? ["scoped-test"] : []);
    assert(existsSync(operation.cwd));
    assert(operation.cwd.startsWith(root));
    assert(operation.command.length > 0);
  }
});
await test("unknown and inherited command names fail", () => {
  assert.throws(() => commandFor("constructor"), /Unknown check/);
  assert.throws(() => commandFor("not-a-check"), /Unknown check/);
});
await test("scope requirements and argument boundaries hold", () => {
  for (const [name, command] of Object.entries(config.commands)) {
    if (command.scoped) assert.throws(() => commandFor(name), /specific test/);
    assert.equal(commandFor(name, ["a test; literal"]).command.at(-1), "a test; literal");
  }
});
await test("child exit status propagates", async () => {
  assert.equal(await execute(["/bin/sh", "-c", "exit 7"]), 7);
});
await test("native checks cannot launch a browser", async () => {
  if (!["web", "extension"].includes(config.surface))
    await assert.rejects(main(["browser", "open", "about:blank"]));
});
await test("unknown browser setup is rejected", async () => {
  await assert.rejects(main(["browser", "setup"]), /Unknown check/);
});
await test("global browser cleanup is rejected", async () => {
  await assert.rejects(main(["browser", "close", "--all"]), /Unknown check/);
});
await test("CLI browser validation completes without an import deadlock", async () => {
  const child = Bun.spawn(
    [process.execPath, "--no-env-file", root + "/tools/qa/run.mjs", "browser"],
    { cwd: root, stdout: "pipe", stderr: "pipe" },
  );
  const timeout = setTimeout(() => child.kill(), 5000);
  try {
    const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
    assert.equal(code, 1);
    assert.match(stderr, /Provide an agent-browser command|Unknown check/);
  } finally {
    clearTimeout(timeout);
  }
});
console.info(passed + " scaffold checks passed");
