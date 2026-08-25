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

export const MIXED_HOST_CREDENTIALS_HINT =
  "Agent key file does not match the API URL. A local key cannot be used on Staging. Pair into .env.agent.staging and restart MCP.";

export function apiEnvironmentId(url: string): string {
  const host = new URL(normalizeApiBaseUrl(url)).hostname.toLowerCase();
  if (
    host === "localhost" ||
    host === "127.0.0.1" ||
    host === "[::1]" ||
    host.endsWith(".localhost")
  ) {
    return "local";
  }
  if (host.includes("staging")) return "staging";
  if (host.includes("production")) return "production";
  return host;
}

export function sameApiEnvironment(left: string, right: string): boolean {
  return apiEnvironmentId(left) === apiEnvironmentId(right);
}

export function boundAgentEnvFileName(apiUrl: string): string {
  const id = apiEnvironmentId(apiUrl);
  if (id === "staging") return ".env.agent.staging";
  if (id === "production") return ".env.agent.production";
  return ".env.agent";
}

export function parseAgentEnvText(text: string): { apiUrl?: string; agentKey?: string } {
  const values: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const i = trimmed.indexOf("=");
    if (i < 0) continue;
    const key = trimmed.slice(0, i).trim();
    let val = trimmed.slice(i + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    values[key] = val;
  }
  const rawUrl = values.KNOCK_KNOCK_API_URL || values.BRIDGE_API_URL;
  const agentKey = values.BRIDGE_AGENT_KEY || values.KNOCK_KNOCK_AGENT_KEY;
  return {
    apiUrl: rawUrl ? normalizeApiBaseUrl(rawUrl) : undefined,
    agentKey: agentKey || undefined,
  };
}

export function agentEnvCandidates(
  moduleUrl: string = import.meta.url,
  requestedApiUrl?: string,
): string[] {
  const override = process.env.KNOCK_KNOCK_AGENT_ENV?.trim();
  const root = workspaceRoot(moduleUrl);
  const canonical = path.resolve(root, ".env.agent");
  const staging = path.resolve(root, ".env.agent.staging");
  const production = path.resolve(root, ".env.agent.production");
  const legacyPackageLocal = path.resolve(mcpPackageRoot(moduleUrl), ".env.agent");
  const envId = requestedApiUrl ? apiEnvironmentId(requestedApiUrl) : undefined;
  const ordered =
    envId === "staging"
      ? [override, staging, canonical, legacyPackageLocal]
      : envId === "production"
        ? [override, production, canonical, legacyPackageLocal]
        : [override, canonical, staging, production, legacyPackageLocal];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const candidate of ordered) {
    if (!candidate) continue;
    const normalized = path.normalize(candidate);
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    out.push(normalized);
  }
  return out;
}

export function selectBoundAgentCredentials(input: {
  requestedApiUrl?: string;
  files: Array<{ path: string; text: string }>;
}):
  | { apiUrl: string; agentKey: string; path: string }
  | { skipped: string[]; hint: string } {
  const requested = input.requestedApiUrl
    ? normalizeApiBaseUrl(input.requestedApiUrl)
    : undefined;
  const skipped: string[] = [];
  for (const file of input.files) {
    const parsed = parseAgentEnvText(file.text);
    if (!parsed.agentKey || !parsed.apiUrl) {
      skipped.push(file.path);
      continue;
    }
    if (requested && !sameApiEnvironment(parsed.apiUrl, requested)) {
      skipped.push(file.path);
      continue;
    }
    return {
      apiUrl: requested ?? parsed.apiUrl,
      agentKey: parsed.agentKey,
      path: file.path,
    };
  }
  return { skipped, hint: MIXED_HOST_CREDENTIALS_HINT };
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
