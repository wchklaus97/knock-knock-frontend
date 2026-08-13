/** Thin HTTP client for Bridge contract URLs. Auth: BRIDGE_AGENT_KEY → X-Agent-Key */

import fs from "node:fs";
import { agentEnvCandidates, normalizeApiBaseUrl } from "./cli-support.js";

function loadAgentEnvFile() {
  const envPath = agentEnvCandidates().find((candidate) => fs.existsSync(candidate));
  if (!envPath) return;
  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
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
    if (process.env[key] === undefined) process.env[key] = val;
  }
}

loadAgentEnvFile();

const API = normalizeApiBaseUrl(
  process.env.KNOCK_KNOCK_API_URL ??
    process.env.BRIDGE_API_URL ??
    "http://127.0.0.1:8787",
);
const KEY = process.env.BRIDGE_AGENT_KEY ?? "";

export async function api<T>(
  pathName: string,
  init: RequestInit & { json?: unknown; agentAuth?: boolean } = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  const agentAuth = init.agentAuth !== false;
  if (agentAuth) {
    if (!KEY) throw new Error("BRIDGE_AGENT_KEY is required (sent as X-Agent-Key)");
    headers.set("X-Agent-Key", KEY);
  }
  if (init.json !== undefined) {
    headers.set("content-type", "application/json");
  }
  const res = await fetch(`${API.replace(/\/+$/, "")}${pathName}`, {
    ...init,
    headers,
    body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
    signal: init.signal ?? AbortSignal.timeout(15_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${pathName}: ${text}`);
  return text ? (JSON.parse(text) as T) : ({} as T);
}

export function bridgeBaseUrl(): string {
  return API;
}
