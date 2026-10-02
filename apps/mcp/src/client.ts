import "./macos-anti-attach.js";

/** Thin HTTP client for Bridge contract URLs. Auth: BRIDGE_AGENT_KEY → X-Agent-Key */

import path from "node:path";
import {
  AgentEnvFileError,
  MIXED_HOST_CREDENTIALS_HINT,
  agentEnvCandidates,
  normalizeApiBaseUrl,
  readAgentEnvFile,
  selectBoundAgentCredentials,
  scrubAgentCredentialEnvironment,
} from "./cli-support.js";
import {
  listenerAuthorityIsRevoked,
  revokeListenerAuthority,
  revokeListenerAuthorityForApiResponse,
} from "./listening.js";
import { listenerHeaders } from "./thread-binding.js";
import {
  WAKE_BROKER_CAPABILITY_HEADER,
  wakeCapabilityClientConfig,
} from "./wake-capability.js";

let credentialBindHint: string | undefined;
let credentialEnvPath: string | undefined;
let credentialIsolationPaths: readonly string[] = Object.freeze([]);
const wakeCapability = wakeCapabilityClientConfig();

type ParentAgentAuthority = Readonly<{
  apiBaseUrl: string;
  agentKey: string;
}>;

type RequestAuthority = Readonly<{
  apiBaseUrl: string;
  agentKey?: string;
  wakeCapability?: NonNullable<typeof wakeCapability>;
}>;

export type AgentApiClient = <T>(
  pathName: string,
  init?: RequestInit & { json?: unknown; agentAuth?: boolean; timeoutMs?: number },
) => Promise<T>;

function loadBoundAgentCredentials(): ParentAgentAuthority | undefined {
  const requested = process.env.KNOCK_KNOCK_API_URL ?? process.env.BRIDGE_API_URL;
  const configuredEnvPath = process.env.KNOCK_KNOCK_AGENT_ENV?.trim();
  const configuredResolved = configuredEnvPath
    ? path.resolve(configuredEnvPath)
    : undefined;
  const files: Array<{ path: string; text: string }> = [];
  const seen = new Set<string>();
  for (const candidate of agentEnvCandidates(undefined, requested)) {
    try {
      const file = readAgentEnvFile(candidate);
      if (seen.has(file.path)) continue;
      seen.add(file.path);
      files.push(file);
    } catch (error: unknown) {
      if (
        error instanceof AgentEnvFileError &&
        error.code === "missing" &&
        candidate !== configuredResolved
      ) {
        continue;
      }
      throw error;
    }
  }
  credentialIsolationPaths = Object.freeze(files.map((file) => file.path));
  const selected = selectBoundAgentCredentials({
    requestedApiUrl: requested,
    files,
  });
  if ("agentKey" in selected) {
    credentialEnvPath = selected.path;
    process.env.KNOCK_KNOCK_API_URL = selected.apiUrl;
    process.env.BRIDGE_API_URL = selected.apiUrl;
    return Object.freeze({
      apiBaseUrl: selected.apiUrl,
      agentKey: selected.agentKey,
    });
  }
  if (requested && files.length > 0) {
    delete process.env.BRIDGE_AGENT_KEY;
    credentialBindHint = selected.hint;
    console.error(`knock-knock ${selected.hint}`);
  }
  return undefined;
}

let parentAgentAuthority: ParentAgentAuthority | undefined;
try {
  if (!wakeCapability) parentAgentAuthority = loadBoundAgentCredentials();
} finally {
  // Backend credentials are parent-owned object state, never process environment.
  scrubAgentCredentialEnvironment(process.env);
}

const API =
  wakeCapability?.brokerUrl ??
  parentAgentAuthority?.apiBaseUrl ??
  normalizeApiBaseUrl(
    process.env.KNOCK_KNOCK_API_URL ??
      process.env.BRIDGE_API_URL ??
      "http://127.0.0.1:8787",
  );
const defaultAuthority: RequestAuthority = Object.freeze({
  apiBaseUrl: API,
  ...(wakeCapability
    ? { wakeCapability }
    : parentAgentAuthority
      ? { agentKey: parentAgentAuthority.agentKey }
      : {}),
});

export function agentCredentialBindHint(): string | undefined {
  return credentialBindHint;
}

export function agentCredentialEnvPath(): string | undefined {
  return credentialEnvPath;
}

export function agentCredentialIsolationPaths(): readonly string[] {
  return credentialIsolationPaths;
}

async function requestWithAuthority<T>(
  authority: RequestAuthority,
  pathName: string,
  init: RequestInit & { json?: unknown; agentAuth?: boolean; timeoutMs?: number } = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  if (!headers.has("user-agent")) {
    headers.set("user-agent", "KnockKnock-MCP/0.1");
  }
  const agentAuth = init.agentAuth !== false;
  if (agentAuth) {
    if (listenerAuthorityIsRevoked()) {
      throw new Error("listener_authority_revoked: refusing API call after authority loss");
    }
    if (authority.wakeCapability) {
      headers.set(
        WAKE_BROKER_CAPABILITY_HEADER,
        authority.wakeCapability.capability,
      );
    } else if (!authority.agentKey) {
      throw new Error(credentialBindHint ?? MIXED_HOST_CREDENTIALS_HINT);
    } else {
      headers.set("X-Agent-Key", authority.agentKey);
      for (const [name, value] of Object.entries(listenerHeaders())) {
        if (!headers.has(name)) headers.set(name, value);
      }
    }
  }
  if (init.json !== undefined) {
    headers.set("content-type", "application/json");
  }
  const { json: _json, agentAuth: _agentAuth, timeoutMs, signal, ...rest } = init;
  const res = await fetch(
    `${authority.apiBaseUrl.replace(/\/+$/, "")}${pathName}`,
    {
    ...rest,
    headers,
    body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
    signal: signal ?? AbortSignal.timeout(timeoutMs ?? 15_000),
    },
  );
  const text = await res.text();
  if (
    !res.ok &&
    authority.wakeCapability &&
    [401, 403, 409, 410].includes(res.status)
  ) {
    revokeListenerAuthority("wake_capability_rejected");
  } else if (!res.ok) {
    revokeListenerAuthorityForApiResponse(res.status, text);
  }
  if (!res.ok) throw new Error(`${res.status} ${pathName}: request failed`);
  return text ? (JSON.parse(text) as T) : ({} as T);
}

export function createParentAgentApiClient(): AgentApiClient {
  const authority = parentAgentAuthority;
  if (!authority || wakeCapability) {
    throw new Error("parent agent authority is unavailable");
  }
  const explicitAuthority: RequestAuthority = Object.freeze({
    apiBaseUrl: authority.apiBaseUrl,
    agentKey: authority.agentKey,
  });
  return <T>(
    pathName: string,
    init: RequestInit & {
      json?: unknown;
      agentAuth?: boolean;
      timeoutMs?: number;
    } = {},
  ) => requestWithAuthority<T>(explicitAuthority, pathName, init);
}

export async function api<T>(
  pathName: string,
  init: RequestInit & { json?: unknown; agentAuth?: boolean; timeoutMs?: number } = {},
): Promise<T> {
  return requestWithAuthority<T>(defaultAuthority, pathName, init);
}

export function bridgeBaseUrl(): string {
  return API;
}
