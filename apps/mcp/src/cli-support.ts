import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MIN_PAIRING_CODE_LENGTH = 4;
const MAX_PAIRING_CODE_LENGTH = 64;

function mcpPackageRoot(moduleUrl: string = import.meta.url): string {
  const moduleDirectory = path.dirname(fileURLToPath(moduleUrl));
  return path.resolve(moduleDirectory, "..");
}

export function workspaceRoot(moduleUrl: string = import.meta.url): string {
  return path.resolve(mcpPackageRoot(moduleUrl), "../..");
}

export function resolveAgentEnvPath(
  fileName: string,
  moduleUrl: string = import.meta.url,
): string {
  if (path.isAbsolute(fileName)) return path.normalize(fileName);
  return path.resolve(workspaceRoot(moduleUrl), fileName);
}

export function agentEnvCandidates(moduleUrl: string = import.meta.url): string[] {
  const canonical = path.resolve(workspaceRoot(moduleUrl), ".env.agent");
  const legacyPackageLocal = path.resolve(mcpPackageRoot(moduleUrl), ".env.agent");
  return [canonical, legacyPackageLocal];
}

export function normalizeApiBaseUrl(value: string): string {
  const trimmed = value.trim();
  if (/\r|\n/.test(trimmed)) {
    throw new Error("--api-url cannot contain line breaks");
  }
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new Error("--api-url must be a valid HTTP(S) URL");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("--api-url must use http or https");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("--api-url cannot contain credentials, a query, or a fragment");
  }
  return parsed.toString().replace(/\/+$/, "");
}

export function normalizePairingCode(value: string): string {
  const code = value.trim();
  if (code.length < MIN_PAIRING_CODE_LENGTH || code.length > MAX_PAIRING_CODE_LENGTH) {
    throw new Error(
      `--code must contain ${MIN_PAIRING_CODE_LENGTH}-${MAX_PAIRING_CODE_LENGTH} characters`,
    );
  }
  return code;
}

export function writeAgentEnvFile(
  fileName: string,
  apiKey: string,
  apiBaseUrl: string,
  force: boolean,
  moduleUrl: string = import.meta.url,
): string {
  const filePath = resolveAgentEnvPath(fileName, moduleUrl);
  if (fs.existsSync(filePath) && !force) {
    throw new Error(`${filePath} already exists; use --force to replace it`);
  }
  if (!apiKey || /\r|\n/.test(apiKey)) {
    throw new Error("agent API key is invalid");
  }
  const normalizedApiBaseUrl = normalizeApiBaseUrl(apiBaseUrl);
  fs.writeFileSync(
    filePath,
    [
      "# Knock Knock agent credentials — keep this file private",
      `KNOCK_KNOCK_API_URL=${normalizedApiBaseUrl}`,
      `BRIDGE_API_URL=${normalizedApiBaseUrl}`,
      `BRIDGE_AGENT_KEY=${apiKey}`,
      "",
    ].join("\n"),
    { encoding: "utf8", mode: 0o600 },
  );
  fs.chmodSync(filePath, 0o600);
  return filePath;
}

export function pairingFailureMessage(
  status: number,
  apiBaseUrl: string,
  detail: string,
): string {
  if (status === 404) {
    return (
      `Pairing code was not found at ${apiBaseUrl}. ` +
      "Pairing codes are environment-specific; generate a fresh code in the phone app " +
      "and pass that app's server URL with --api-url."
    );
  }
  if (status === 409 || status === 410) {
    return `${status} pairing failed at ${apiBaseUrl}: ${detail}. Generate a fresh one-time code.`;
  }
  return `${status} pairing failed at ${apiBaseUrl}: ${detail}`;
}
