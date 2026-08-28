import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MIN_PAIRING_CODE_LENGTH = 4;
const MAX_PAIRING_CODE_LENGTH = 64;
const SUPPORTED_AGENT_ENV_KEYS = new Set([
  "KNOCK_KNOCK_API_URL",
  "BRIDGE_API_URL",
  "BRIDGE_AGENT_KEY",
  "KNOCK_KNOCK_AGENT_KEY",
]);
export const AGENT_CREDENTIAL_ENV_ALIASES = Object.freeze([
  "BRIDGE_AGENT_KEY",
  "KNOCK_KNOCK_AGENT_KEY",
  "KNOCK_KNOCK_AGENT_ENV",
] as const);
const SAFE_AGENT_ENV_VALUE = /^[A-Za-z0-9._~:/%+@=-]+$/;
export const MAX_AGENT_ENV_FILE_BYTES = 16 * 1024;

export class AgentEnvFileError extends Error {
  constructor(
    readonly code: "missing" | "invalid",
    message: string,
  ) {
    super(message);
    this.name = "AgentEnvFileError";
  }
}

export type SecureAgentEnvFile = Readonly<{
  path: string;
  text: string;
}>;

type AgentEnvFileValidationOptions = Readonly<{
  currentUid?: number;
  maxBytes?: number;
}>;

function agentEnvErrorCode(error: unknown): string | undefined {
  return error && typeof error === "object" && "code" in error
    ? String((error as NodeJS.ErrnoException).code)
    : undefined;
}

function resolvedAgentEnvPath(filePath: string): string {
  const trimmed = filePath.trim();
  if (!trimmed || /[\0\r\n]/.test(trimmed)) {
    throw new AgentEnvFileError("invalid", "agent environment path is invalid");
  }
  return path.resolve(trimmed);
}

function secureAgentEnvOpenFlags(access: number): number {
  const noFollow = fs.constants.O_NOFOLLOW;
  if (typeof noFollow !== "number" || noFollow === 0) {
    throw new AgentEnvFileError(
      "invalid",
      "secure no-follow credential access is unavailable",
    );
  }
  const nonBlock = fs.constants.O_NONBLOCK;
  if (typeof nonBlock !== "number" || nonBlock === 0) {
    throw new AgentEnvFileError(
      "invalid",
      "secure non-blocking credential access is unavailable",
    );
  }
  return access | noFollow | nonBlock | (fs.constants.O_CLOEXEC ?? 0);
}

export function scrubAgentCredentialEnvironment(
  env: NodeJS.ProcessEnv = process.env,
): void {
  for (const alias of AGENT_CREDENTIAL_ENV_ALIASES) delete env[alias];
}

function sameFile(left: fs.Stats, right: fs.Stats): boolean {
  return left.dev === right.dev && left.ino === right.ino;
}

function validateOpenAgentEnvFile(
  descriptor: number,
  resolvedPath: string,
  options: AgentEnvFileValidationOptions = {},
): { path: string; stat: fs.Stats } {
  const maxBytes = options.maxBytes ?? MAX_AGENT_ENV_FILE_BYTES;
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
    throw new AgentEnvFileError("invalid", "agent environment size limit is invalid");
  }

  const descriptorStat = fs.fstatSync(descriptor);
  if (!descriptorStat.isFile()) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment path must name a regular file",
    );
  }
  const currentUid = options.currentUid ?? process.getuid?.();
  if (currentUid === undefined || descriptorStat.uid !== currentUid) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file must be owned by the current user",
    );
  }
  if ((descriptorStat.mode & 0o777) !== 0o600) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file must use mode 0600 and must not grant group or other permissions",
    );
  }
  if (descriptorStat.nlink !== 1) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file must not have hard-link aliases",
    );
  }
  if (descriptorStat.size < 0 || descriptorStat.size > maxBytes) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file exceeds the secure size limit",
    );
  }

  let pathStat: fs.Stats;
  let canonicalPath: string;
  let canonicalStat: fs.Stats;
  try {
    pathStat = fs.lstatSync(resolvedPath);
    canonicalPath = fs.realpathSync.native(resolvedPath);
    canonicalStat = fs.statSync(canonicalPath);
  } catch {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file changed during secure access",
    );
  }
  if (
    pathStat.isSymbolicLink() ||
    !pathStat.isFile() ||
    !sameFile(descriptorStat, pathStat) ||
    !sameFile(descriptorStat, canonicalStat)
  ) {
    throw new AgentEnvFileError(
      "invalid",
      "agent environment path must name one stable regular non-symlink file",
    );
  }
  return { path: canonicalPath, stat: descriptorStat };
}

function openExistingAgentEnvFile(
  filePath: string,
  access: number,
): { descriptor: number; path: string } {
  const resolvedPath = resolvedAgentEnvPath(filePath);
  try {
    return {
      descriptor: fs.openSync(resolvedPath, secureAgentEnvOpenFlags(access)),
      path: resolvedPath,
    };
  } catch (error: unknown) {
    if (agentEnvErrorCode(error) === "ENOENT") {
      throw new AgentEnvFileError("missing", "agent environment file is missing");
    }
    if (["ELOOP", "EMLINK", "EFTYPE"].includes(agentEnvErrorCode(error) ?? "")) {
      throw new AgentEnvFileError(
        "invalid",
        "agent environment path must name a regular file",
      );
    }
    if (error instanceof AgentEnvFileError) throw error;
    throw new AgentEnvFileError(
      "invalid",
      "agent environment file could not be opened securely",
    );
  }
}

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
  "Agent key file does not exactly match the API URL. Localhost, 127.0.0.1, and [::1] are interchangeable only when scheme, effective port, and base path match. Pair for this exact API URL and restart MCP.";

export const KNOCK_KNOCK_STAGING_API_ORIGIN =
  "https://knock-knock-backend-staging.wch-klaus.workers.dev";
export const KNOCK_KNOCK_PRODUCTION_API_ORIGIN =
  "https://knock-knock-backend-production.wch-klaus.workers.dev";

function loopbackHostClass(hostname: string): "loopback" | undefined {
  const normalized = hostname.toLowerCase();
  return normalized === "localhost" ||
    normalized === "127.0.0.1" ||
    normalized === "[::1]" ||
    normalized === "::1"
    ? "loopback"
    : undefined;
}

function effectiveApiPort(url: URL): string {
  if (url.port) return url.port;
  return url.protocol === "https:" ? "443" : "80";
}

function normalizedApiBasePath(url: URL): string {
  const pathname = url.pathname || "/";
  return pathname === "/" ? pathname : pathname.replace(/\/+$/, "");
}

export function apiEnvironmentId(url: string): string {
  const normalized = normalizeApiBaseUrl(url);
  if (normalized === KNOCK_KNOCK_STAGING_API_ORIGIN) return "staging";
  if (normalized === KNOCK_KNOCK_PRODUCTION_API_ORIGIN) return "production";
  const parsed = new URL(normalized);
  const loopbackClass = loopbackHostClass(parsed.hostname);
  if (loopbackClass) {
    return [
      "local",
      parsed.protocol,
      loopbackClass,
      effectiveApiPort(parsed),
      normalizedApiBasePath(parsed),
    ].join("|");
  }
  return `custom:${normalized}`;
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
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    let line = lines[index];
    if (line.endsWith("\r")) line = line.slice(0, -1);
    if (!line || line.startsWith("#")) continue;
    if (line !== line.trim() || line.includes("\r") || line.includes("\0")) {
      throw new Error(`agent environment file is malformed on line ${index + 1}`);
    }
    const separator = line.indexOf("=");
    if (separator <= 0) {
      throw new Error(`agent environment file is malformed on line ${index + 1}`);
    }
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (!SUPPORTED_AGENT_ENV_KEYS.has(key)) {
      throw new Error(`agent environment file has an unsupported entry on line ${index + 1}`);
    }
    if (!value || !SAFE_AGENT_ENV_VALUE.test(value)) {
      throw new Error(`agent environment file has an unsafe value on line ${index + 1}`);
    }
    if (Object.hasOwn(values, key)) {
      throw new Error(`agent environment file repeats ${key}`);
    }
    values[key] = value;
  }

  const knockUrl = values.KNOCK_KNOCK_API_URL
    ? normalizeApiBaseUrl(values.KNOCK_KNOCK_API_URL)
    : undefined;
  const bridgeUrl = values.BRIDGE_API_URL
    ? normalizeApiBaseUrl(values.BRIDGE_API_URL)
    : undefined;
  if (knockUrl && bridgeUrl && knockUrl !== bridgeUrl) {
    throw new Error("agent environment file contains conflicting API URLs");
  }
  const bridgeKey = values.BRIDGE_AGENT_KEY;
  const knockKey = values.KNOCK_KNOCK_AGENT_KEY;
  if (bridgeKey && knockKey && bridgeKey !== knockKey) {
    throw new Error("agent environment file contains conflicting agent keys");
  }
  return {
    apiUrl: knockUrl ?? bridgeUrl,
    agentKey: bridgeKey ?? knockKey,
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
      ? [staging, override, canonical, legacyPackageLocal]
      : envId === "production"
        ? [production, override, canonical, legacyPackageLocal]
        : [canonical, override, staging, production, legacyPackageLocal];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const candidate of ordered) {
    if (!candidate) continue;
    const normalized = path.resolve(candidate);
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    out.push(normalized);
  }
  return out;
}

export function validateAgentEnvFilePath(
  filePath: string,
  options: AgentEnvFileValidationOptions = {},
): string {
  const opened = openExistingAgentEnvFile(filePath, fs.constants.O_RDONLY);
  try {
    validateOpenAgentEnvFile(opened.descriptor, opened.path, options);
    return opened.path;
  } finally {
    fs.closeSync(opened.descriptor);
  }
}

export function canonicalAgentEnvFilePath(
  filePath: string,
  options: AgentEnvFileValidationOptions = {},
): string {
  const opened = openExistingAgentEnvFile(filePath, fs.constants.O_RDONLY);
  try {
    return validateOpenAgentEnvFile(opened.descriptor, opened.path, options).path;
  } finally {
    fs.closeSync(opened.descriptor);
  }
}

export function readAgentEnvFile(
  filePath: string,
  options: AgentEnvFileValidationOptions = {},
): SecureAgentEnvFile {
  const opened = openExistingAgentEnvFile(filePath, fs.constants.O_RDONLY);
  try {
    const validated = validateOpenAgentEnvFile(opened.descriptor, opened.path, options);
    const bytes = Buffer.alloc(validated.stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const read = fs.readSync(
        opened.descriptor,
        bytes,
        offset,
        bytes.length - offset,
        offset,
      );
      if (read === 0) {
        throw new AgentEnvFileError(
          "invalid",
          "agent environment file changed during secure access",
        );
      }
      offset += read;
    }
    const afterRead = fs.fstatSync(opened.descriptor);
    if (!sameFile(validated.stat, afterRead) || afterRead.size !== validated.stat.size) {
      throw new AgentEnvFileError(
        "invalid",
        "agent environment file changed during secure access",
      );
    }
    return Object.freeze({
      path: validated.path,
      text: bytes.toString("utf8"),
    });
  } finally {
    fs.closeSync(opened.descriptor);
  }
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
    // Key-only legacy files have no endpoint authority. Do not assign them the
    // process default: a local key is usable only when its file binds a URL.
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
  if (!apiKey || !SAFE_AGENT_ENV_VALUE.test(apiKey)) {
    throw new Error("agent API key is invalid");
  }
  const normalizedApiBaseUrl = normalizeApiBaseUrl(apiBaseUrl);
  const contents = [
    "# Knock Knock agent credentials - keep this file private",
    `KNOCK_KNOCK_API_URL=${normalizedApiBaseUrl}`,
    `BRIDGE_API_URL=${normalizedApiBaseUrl}`,
    `BRIDGE_AGENT_KEY=${apiKey}`,
    "",
  ].join("\n");
  if (Buffer.byteLength(contents) > MAX_AGENT_ENV_FILE_BYTES) {
    throw new Error("agent environment file exceeds the secure size limit");
  }

  const resolvedPath = resolvedAgentEnvPath(filePath);
  let descriptor: number;
  let created = false;
  if (force) {
    try {
      descriptor = fs.openSync(
        resolvedPath,
        secureAgentEnvOpenFlags(fs.constants.O_WRONLY),
      );
    } catch (error: unknown) {
      if (agentEnvErrorCode(error) !== "ENOENT") {
        throw new Error("agent environment file could not be opened securely");
      }
      descriptor = fs.openSync(
        resolvedPath,
        secureAgentEnvOpenFlags(
          fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
        ),
        0o600,
      );
      created = true;
    }
  } else {
    try {
      descriptor = fs.openSync(
        resolvedPath,
        secureAgentEnvOpenFlags(
          fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
        ),
        0o600,
      );
      created = true;
    } catch (error: unknown) {
      if (agentEnvErrorCode(error) === "EEXIST") {
        throw new Error(`${filePath} already exists; use --force to replace it`);
      }
      throw new Error("agent environment file could not be created securely");
    }
  }

  try {
    if (created) fs.fchmodSync(descriptor, 0o600);
    const validated = validateOpenAgentEnvFile(descriptor, resolvedPath);
    fs.ftruncateSync(descriptor, 0);
    fs.writeFileSync(descriptor, contents, { encoding: "utf8" });
    fs.fsyncSync(descriptor);
    return validated.path;
  } finally {
    fs.closeSync(descriptor);
  }
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
