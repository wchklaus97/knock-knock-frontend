import {
  spawn as nodeSpawn,
  spawnSync,
  type ChildProcess,
} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { canonicalAgentEnvFilePath } from "./cli-support.js";

const MACOS_SANDBOX_EXECUTABLE = "/usr/bin/sandbox-exec";

export type MacOSWakeSandboxSpawnOptions = Readonly<{
  env: NodeJS.ProcessEnv;
  detached: boolean;
}>;

function sandboxString(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export function buildMacOSCredentialSandboxProfile(
  credentialPaths: readonly string[],
): string {
  if (credentialPaths.length === 0) {
    throw new Error("wake credential isolation paths are unavailable");
  }
  const unique = [...new Set(credentialPaths)];
  for (const credentialPath of unique) {
    if (!path.isAbsolute(credentialPath) || /[\0\r\n]/.test(credentialPath)) {
      throw new Error("wake credential isolation path is invalid");
    }
  }
  return [
    "(version 1)",
    "(allow default)",
    "(deny system-audit)",
    "(deny mach-priv-host-port)",
    "(deny process-info* (target others))",
    "(deny process-info-setcontrol (target others))",
    "(deny mach-task-name (target others))",
    "(deny mach-task-read (target others))",
    "(deny mach-task-special-port*)",
    '(deny mach-lookup (global-name "com.apple.taskgated"))',
    '(deny mach-lookup (global-name "com.apple.taskgated.helper"))',
    '(deny mach-lookup (global-name "com.apple.taskgated.mach"))',
    '(deny authorization-right-obtain (right-name "system.privilege.taskport"))',
    '(deny authorization-right-obtain (right-name "system.privilege.taskport.debug"))',
    '(deny process-exec (regex #".*/debugserver$"))',
    '(deny file-read* (regex #".*/debugserver$"))',
    '(deny file-map-executable (regex #".*/debugserver$"))',
    ...unique.flatMap((credentialPath) => [
      `(deny file-read* (literal ${sandboxString(credentialPath)}))`,
      `(deny file-write* (literal ${sandboxString(credentialPath)}))`,
    ]),
    "",
  ].join("\n");
}

function assertMacOSWakeSandboxProfileInstalls(profile: string): void {
  const result = spawnSync(
    MACOS_SANDBOX_EXECUTABLE,
    ["-f", "/dev/stdin", "/usr/bin/true"],
    {
      input: profile,
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5_000,
    },
  );
  if (result.error || result.status !== 0 || result.signal) {
    throw new Error("macOS Seatbelt profile is invalid or unavailable");
  }
}

export function assertMacOSWakeSandboxAvailable(
  credentialPaths: readonly string[],
  platform: NodeJS.Platform = process.platform,
): readonly string[] {
  if (platform !== "darwin") {
    throw new Error("Codex wake credential isolation requires macOS Seatbelt");
  }
  let executableStat: fs.Stats;
  try {
    executableStat = fs.lstatSync(MACOS_SANDBOX_EXECUTABLE);
  } catch {
    throw new Error("macOS Seatbelt launcher is unavailable");
  }
  if (
    !executableStat.isFile() ||
    executableStat.isSymbolicLink() ||
    executableStat.uid !== 0 ||
    (executableStat.mode & 0o111) === 0 ||
    fs.realpathSync.native(MACOS_SANDBOX_EXECUTABLE) !== MACOS_SANDBOX_EXECUTABLE
  ) {
    throw new Error("macOS Seatbelt launcher is not trusted");
  }
  const validated = credentialPaths.map((credentialPath) =>
    canonicalAgentEnvFilePath(credentialPath),
  );
  const unique = Object.freeze([...new Set(validated)]);
  if (unique.length === 0) {
    throw new Error("wake credential isolation paths are unavailable");
  }
  assertMacOSWakeSandboxProfileInstalls(
    buildMacOSCredentialSandboxProfile(unique),
  );
  return unique;
}

export function spawnMacOSCredentialSandboxedProcess(
  command: string,
  args: readonly string[],
  options: MacOSWakeSandboxSpawnOptions,
  credentialPaths: readonly string[],
): ChildProcess {
  const isolatedPaths = assertMacOSWakeSandboxAvailable(credentialPaths);
  const profile = buildMacOSCredentialSandboxProfile(isolatedPaths);
  const child = nodeSpawn(
    MACOS_SANDBOX_EXECUTABLE,
    ["-f", "/dev/stdin", command, ...args],
    {
      stdio: ["pipe", "ignore", "ignore"],
      env: { ...options.env },
      detached: options.detached,
    },
  );
  const profileInput = child.stdin;
  if (!profileInput) {
    child.kill("SIGKILL");
    throw new Error("macOS Seatbelt profile channel is unavailable");
  }
  profileInput.on("error", () => {
    // Spawn/exit handlers own process failure; never leave an unhandled pipe error.
  });
  try {
    profileInput.end(profile, "utf8");
  } catch (error: unknown) {
    profileInput.destroy();
    child.kill("SIGKILL");
    throw error;
  }
  return child;
}
