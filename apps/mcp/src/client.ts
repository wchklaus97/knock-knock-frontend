/** Thin HTTP client for Bridge contract URLs. Auth: BRIDGE_AGENT_KEY → X-Agent-Key */

import fs from "node:fs";
import {
  MIXED_HOST_CREDENTIALS_HINT,
  agentEnvCandidates,
  normalizeApiBaseUrl,
  selectBoundAgentCredentials,
} from "./cli-support.js";
import { listenerHeaders } from "./thread-binding.js";

let credentialBindHint: string | undefined;

function loadBoundAgentCredentials() {
  const requested = process.env.KNOCK_KNOCK_API_URL ?? process.env.BRIDGE_API_URL;
  const files = agentEnvCandidates(undefined, requested)
    .filter((candidate) => fs.existsSync(candidate))
    .map((envPath) => ({ path: envPath, text: fs.readFileSync(envPath, "utf8") }));
  const selected = selectBoundAgentCredentials({
    requestedApiUrl: requested,
    files,
  });
  if ("agentKey" in selected) {
    process.env.KNOCK_KNOCK_API_URL = selected.apiUrl;
    process.env.BRIDGE_API_URL = selected.apiUrl;
    process.env.BRIDGE_AGENT_KEY = selected.agentKey;
    return;
  }
  if (requested && files.length > 0) {
    delete process.env.BRIDGE_AGENT_KEY;
    credentialBindHint = selected.hint;
    console.error(`knock-knock ${selected.hint}`);
  }
}

loadBoundAgentCredentials();

const API = normalizeApiBaseUrl(
  process.env.KNOCK_KNOCK_API_URL ??
    process.env.BRIDGE_API_URL ??
    "http://127.0.0.1:8787",
);
const KEY = process.env.BRIDGE_AGENT_KEY ?? "";

export function agentCredentialBindHint(): string | undefined {
  return credentialBindHint;
}

export async function api<T>(
  pathName: string,
  init: RequestInit & { json?: unknown; agentAuth?: boolean; timeoutMs?: number } = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  if (!headers.has("user-agent")) {
    headers.set("user-agent", "KnockKnock-MCP/0.1");
  }
  const agentAuth = init.agentAuth !== false;
  if (agentAuth) {
    if (!KEY) {
      throw new Error(credentialBindHint ?? MIXED_HOST_CREDENTIALS_HINT);
    }
    headers.set("X-Agent-Key", KEY);
    for (const [name, value] of Object.entries(listenerHeaders())) {
      if (!headers.has(name)) headers.set(name, value);
    }
  }
  if (init.json !== undefined) {
    headers.set("content-type", "application/json");
  }
  const { json: _json, agentAuth: _agentAuth, timeoutMs, signal, ...rest } = init;
  const res = await fetch(`${API.replace(/\/+$/, "")}${pathName}`, {
    ...rest,
    headers,
    body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
    signal: signal ?? AbortSignal.timeout(timeoutMs ?? 15_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${pathName}: ${text}`);
  return text ? (JSON.parse(text) as T) : ({} as T);
}

export function bridgeBaseUrl(): string {
  return API;
}
