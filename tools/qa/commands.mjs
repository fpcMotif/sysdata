import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const config = JSON.parse(readFileSync(new URL("./config.json", import.meta.url), "utf8"));

export function commandFor(name, args = []) {
  if (!Object.hasOwn(config.commands, name)) throw new Error("Unknown check: " + name);
  const spec = config.commands[name];
  if (spec.scoped && (!args.length || args.every((arg) => arg.startsWith("-")))) {
    throw new Error("Provide a specific test file or harness name");
  }
  const cwd = resolve(root, spec.cwd ?? ".");
  if (cwd !== root && !cwd.startsWith(root + sep))
    throw new Error("Check directory must stay inside this project");
  if (!existsSync(cwd)) throw new Error("Missing check directory: " + cwd);
  return { cwd, command: environmentCommand([...spec.argv, ...args]) };
}

function environmentCommand(command) {
  if (
    (existsSync(resolve(root, "mise.toml")) || existsSync(resolve(root, ".mise.toml"))) &&
    command[0] !== "mise"
  ) {
    command = ["mise", "exec", "--", ...command];
  }
  if (existsSync(resolve(root, ".envrc"))) command = ["direnv", "exec", root, ...command];
  return command;
}

export async function execute(command, cwd = root) {
  const child = Bun.spawn(command, { cwd, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  const interrupt = () => child.kill("SIGINT");
  const terminate = () => child.kill("SIGTERM");
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", terminate);
  try {
    return await child.exited;
  } finally {
    process.off("SIGINT", interrupt);
    process.off("SIGTERM", terminate);
  }
}
