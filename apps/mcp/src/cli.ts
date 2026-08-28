#!/usr/bin/env node
/**
 * `vab` CLI — pair | session | progress | event | pending | result
 */
import { api, bridgeBaseUrl } from "./client.js";
import { pathToFileURL } from "node:url";
import {
  claimAgentAsks,
  readAgentAsks,
} from "./ask-transport.js";
import {
  boundAgentEnvFileName,
  normalizeApiBaseUrl,
  normalizePairingCode,
  pairingFailureMessage,
  writeAgentEnvFile,
} from "./cli-support.js";
import {
  createListeningShutdownController,
  listeningHeartbeatPath,
  listeningRegistrationPath,
  negotiateListenerLease,
  releaseListeningLease,
  startListeningHeartbeat,
  type ListeningHeartbeatHandle,
  type ListeningShutdownController,
  type ListeningShutdownEventSource,
} from "./listening.js";
import { safeErrorMessage, sanitizeSensitiveData } from "./redaction.js";
import { listenerRegistrationBody, listenerRenewalBody } from "./thread-binding.js";

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

function printJson(value: unknown): void {
  console.log(JSON.stringify(sanitizeSensitiveData(value), null, 2));
}

function usage(code = 0): never {
  console.log(`Usage:
  vab pair --code pair_... --label my-agent [--host cli] [--api-url URL] [--write-env .env.agent [--force]]
  vab session --skill deploy.result [--session ses_...] [--title ...] [--chat ...]
  vab progress --session ses_... --status running [--message "..."] [--percent 0-100]
  vab event --session ses_... --status needs_user --idemp KEY [--summary "..." ] [--service api] [--env prod] [--fact_status 失败] [--actions rollback,ack] [--force-push]
  vab pending [--session ses_...] [--claim false]
  vab asks [--claim true] [--takeover true]
  vab listen [--takeover true]
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

function cliListeningTransport() {
  return {
    acquire: (takeover: boolean) =>
      api(listeningRegistrationPath(), {
        method: "POST",
        json: listenerRegistrationBody(takeover),
        timeoutMs: 5_000,
      }),
    renew: (lease: Parameters<typeof listenerRenewalBody>[0]) =>
      api(listeningHeartbeatPath(), {
        method: "POST",
        json: listenerRenewalBody(lease),
        timeoutMs: 5_000,
      }),
    release: (lease: Parameters<typeof listenerRenewalBody>[0]) =>
      releaseListeningLease(
        (path, init) =>
          api(path, {
            ...init,
            timeoutMs: 5_000,
          }),
        lease,
      ),
  };
}

export async function runCliListenerLifecycle<T>(
  heartbeat: ListeningHeartbeatHandle,
  operation: (shutdown: ListeningShutdownController) => Promise<T>,
  options: {
    processEvents?: ListeningShutdownEventSource;
    inputEvents?: ListeningShutdownEventSource;
    onError?: (error: unknown) => void;
  } = {},
): Promise<T> {
  const processEvents = options.processEvents ?? process;
  const inputEvents = options.inputEvents ?? process.stdin;
  const shutdown = createListeningShutdownController(heartbeat, {
    bindings: [
      { source: processEvents, event: "SIGINT", reason: "sigint" },
      { source: processEvents, event: "SIGTERM", reason: "sigterm" },
      { source: inputEvents, event: "end", reason: "stdin_end" },
      { source: inputEvents, event: "close", reason: "stdin_close" },
    ],
    onError: options.onError ?? ((error) => console.error(safeErrorMessage(error))),
  });
  try {
    return await operation(shutdown);
  } catch (error: unknown) {
    await shutdown.stop("cli_fatal");
    throw error;
  } finally {
    await shutdown.stop("cli_return");
  }
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
        const writePath =
          envPath === ".env.agent" ? boundAgentEnvFileName(pairingApiUrl) : envPath;
        const written = writeAgentEnvFile(
          writePath,
          json.api_key,
          pairingApiUrl,
          hasFlag("force"),
        );
        printJson({ env_file: written, api_url: pairingApiUrl });
        console.error(`Saved agent credentials to ${written}`);
      } else {
        printJson(json);
      }
      if (json.api_key && !envPath) {
        console.error("\nCredential output was redacted; use --write-env to store it securely.");
      }
      break;
    }
    case "session": {
      printJson(
        await api("/v1/sessions", {
          method: "POST",
          json: {
            skill_id: arg("skill", "deploy.result"),
            session_id: arg("session"),
            title: arg("title"),
            chat_id: arg("chat"),
          },
        }),
      );
      break;
    }
    case "progress": {
      const sid = arg("session");
      if (!sid) throw new Error("--session required");
      const percent = numberArg("percent");
      printJson(
        await api(`/v1/sessions/${encodeURIComponent(sid)}/progress`, {
          method: "POST",
          json: { status: arg("status", "running"), message: arg("message"), percent },
        }),
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
      printJson(
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
      printJson(await api(path));
      break;
    }
    case "asks": {
      const claim = arg("claim", "false") === "true";
      const registration = await api(listeningRegistrationPath(), {
        method: "POST",
        json: listenerRegistrationBody(arg("takeover", "false") === "true"),
        timeoutMs: 5_000,
      });
      const lease = negotiateListenerLease(registration);
      if (!lease && claim) {
        throw new Error("legacy listener is drain-only and cannot claim Ask authority");
      }
      if (!lease) console.error("legacy listener detected: explicit drain-only mode");
      const readOrClaim = async () => {
        if (claim) {
          const claimResponse = await claimAgentAsks(
            (path, init) => api(path, init),
          );
          const safeClaimOutput = sanitizeSensitiveData(claimResponse);
          printJson(safeClaimOutput);
        } else {
          printJson(
            await readAgentAsks((path, init) => api(path, init)),
          );
        }
      };
      if (lease) {
        const heartbeat = startListeningHeartbeat(cliListeningTransport(), {
          inheritedFence: lease,
          inheritedFenceOwned: true,
        });
        await runCliListenerLifecycle(heartbeat, readOrClaim);
      } else {
        await readOrClaim();
      }
      break;
    }
    case "listen": {
      console.error(`listening on ${bridgeBaseUrl()} (thread-bound lease heartbeat)`);
      const heartbeat = startListeningHeartbeat(
        cliListeningTransport(),
        { takeover: arg("takeover", "false") === "true" },
      );
      await runCliListenerLifecycle(heartbeat, (shutdown) => shutdown.wait());
      break;
    }
    case "result": {
      const id = arg("action");
      if (!id) throw new Error("--action required");
      printJson(
        await api(`/v1/actions/${encodeURIComponent(id)}/result`, {
          method: "POST",
          json: {
            ok: arg("ok", "true") === "true",
            message: arg("message", "done"),
          },
        }),
      );
      break;
    }
    default:
      usage(1);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void main().catch((e: unknown) => {
    console.error(safeErrorMessage(e));
    process.exitCode = 1;
  });
}
