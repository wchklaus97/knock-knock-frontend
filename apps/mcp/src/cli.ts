#!/usr/bin/env node
/**
 * `vab` CLI — pair | session | progress | event | pending | result
 */
import { api, bridgeBaseUrl } from "./client.js";
import {
  normalizeApiBaseUrl,
  normalizePairingCode,
  pairingFailureMessage,
  writeAgentEnvFile,
} from "./cli-support.js";

const rawArgs = process.argv.slice(2);
// pnpm forwards a separator for the documented `pnpm ... cli -- pair` form.
// Accept both that form and the direct `exec tsx src/cli.ts pair` form.
const [cmd, ...rest] = rawArgs[0] === "--" ? rawArgs.slice(1) : rawArgs;

function arg(name: string, fallback?: string): string | undefined {
  const i = rest.indexOf(`--${name}`);
  if (i >= 0) return rest[i + 1];
  return fallback;
}

function valueArg(name: string): string | undefined {
  const i = rest.indexOf(`--${name}`);
  const value = i >= 0 ? rest[i + 1] : undefined;
  return value && !value.startsWith("--") ? value : undefined;
}

function hasFlag(name: string): boolean {
  return rest.includes(`--${name}`);
}

function numberArg(name: string): number | undefined {
  const value = arg(name);
  if (value === undefined) return undefined;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 100) {
    throw new Error(`--${name} must be a number between 0 and 100`);
  }
  return parsed;
}

function usage(code = 0): never {
  console.log(`Usage:
  vab pair --code pair_... --label my-agent [--host cli] [--api-url URL] [--write-env .env.agent [--force]]
  vab session --skill deploy.result [--session ses_...] [--title ...] [--chat ...]
  vab progress --session ses_... --status running [--message "..."] [--percent 0-100]
  vab event --session ses_... --status needs_user --idemp KEY [--summary "..." ] [--service api] [--env prod] [--fact_status 失败] [--actions rollback,ack] [--force-push]
  vab pending [--session ses_...] [--claim false]
  vab result --action act_... [--ok true|false] [--message done]

Env:
  KNOCK_KNOCK_API_URL Rust Worker URL (preferred)
  BRIDGE_API_URL     compatibility alias; default http://127.0.0.1:8787
  BRIDGE_AGENT_KEY   required except for pair (X-Agent-Key)

Notes:
  progress NEVER pushes; event MAY push (needs_user / actions / --force-push).
`);
  process.exit(code);
}

async function main(): Promise<void> {
  if (!cmd || cmd === "-h" || cmd === "--help") usage(0);

  switch (cmd) {
    case "pair": {
      const rawCode = arg("code");
      const label = arg("label", "cli-agent");
      if (!rawCode) throw new Error("--code required");
      const code = normalizePairingCode(rawCode);
      const pairingApiUrl = normalizeApiBaseUrl(arg("api-url") ?? bridgeBaseUrl());
      const res = await fetch(`${pairingApiUrl}/v1/pairing/claim`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          code,
          label,
          host_label: arg("host", "cli"),
        }),
      });
      const responseText = await res.text();
      let json: { api_key?: string; error?: string; message?: string } = {};
      try {
        json = responseText ? (JSON.parse(responseText) as typeof json) : {};
      } catch {
        json = { error: responseText || "Unknown response" };
      }
      if (!res.ok) {
        const detail = json.message ?? json.error ?? responseText ?? "Unknown response";
        throw new Error(pairingFailureMessage(res.status, pairingApiUrl, detail));
      }
      const envPath = valueArg("write-env");
      if (envPath && json.api_key) {
        const written = writeAgentEnvFile(
          envPath,
          json.api_key,
          pairingApiUrl,
          hasFlag("force"),
        );
        console.log(JSON.stringify({ env_file: written, api_url: pairingApiUrl }, null, 2));
        console.error(`Saved agent credentials to ${written}`);
      } else {
        console.log(JSON.stringify(json, null, 2));
      }
      if (json.api_key && !envPath) {
        console.error(`\nExport: export BRIDGE_AGENT_KEY=${json.api_key}`);
      }
      break;
    }
    case "session": {
      console.log(
        JSON.stringify(
          await api("/v1/sessions", {
            method: "POST",
            json: {
              skill_id: arg("skill", "deploy.result"),
              session_id: arg("session"),
              title: arg("title"),
              chat_id: arg("chat"),
            },
          }),
          null,
          2,
        ),
      );
      break;
    }
    case "progress": {
      const sid = arg("session");
      if (!sid) throw new Error("--session required");
      const percent = numberArg("percent");
      console.log(
        JSON.stringify(
          await api(`/v1/sessions/${encodeURIComponent(sid)}/progress`, {
            method: "POST",
            json: { status: arg("status", "running"), message: arg("message"), percent },
          }),
          null,
          2,
        ),
      );
      break;
    }
    case "event": {
      const sid = arg("session");
      if (!sid) throw new Error("--session required");
      const actions = (arg("actions", "rollback,ack") ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      console.log(
        JSON.stringify(
          await api(`/v1/sessions/${encodeURIComponent(sid)}/events`, {
            method: "POST",
            json: {
              status: arg("status", "needs_user"),
              idempotency_key: arg("idemp", `cli-${Date.now()}`),
              summary: arg("summary"),
              facts: {
                service: arg("service", "api"),
                status: arg("fact_status", "失败"),
                env: arg("env", "prod"),
              },
              actions,
              force_push: rest.includes("--force-push") || arg("force-push") === "true",
            },
          }),
          null,
          2,
        ),
      );
      break;
    }
    case "pending": {
      const sid = arg("session");
      const claim = arg("claim", "true") !== "false";
      const q = `claim=${claim ? "true" : "false"}`;
      const path = sid
        ? `/v1/sessions/${encodeURIComponent(sid)}/actions/pending?${q}`
        : `/v1/agents/me/actions/pending?${q}`;
      console.log(JSON.stringify(await api(path), null, 2));
      break;
    }
    case "result": {
      const id = arg("action");
      if (!id) throw new Error("--action required");
      console.log(
        JSON.stringify(
          await api(`/v1/actions/${encodeURIComponent(id)}/result`, {
            method: "POST",
            json: {
              ok: arg("ok", "true") === "true",
              message: arg("message", "done"),
            },
          }),
          null,
          2,
        ),
      );
      break;
    }
    default:
      usage(1);
  }
}

main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
