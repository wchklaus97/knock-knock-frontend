#!/usr/bin/env node
/**
 * Voice Agent Bridge MCP server (stdio).
 * Tools call BRIDGE_API_URL with X-Agent-Key from BRIDGE_AGENT_KEY.
 *
 * Push: update_progress NEVER pushes; report_event MAY push.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { pathToFileURL } from "node:url";
import { z } from "zod";
import {
  beginPhoneAskProgressRequest,
  completePhoneAskProgressRequest,
  executeDirectPhoneAskAnswer,
  hasUnsettledAskClaimForSession,
  markPhoneAskClaimFailure,
  trackAgentAskResponse,
} from "./ask-claims.js";
import {
  claimAgentAsks,
  createAskClaimQueue,
} from "./ask-transport.js";
import { agentCredentialBindHint, api } from "./client.js";
import {
  agentAuthFailureMessage,
  createListeningShutdownController,
  listeningHeartbeatPath,
  listeningRegistrationPath,
  releaseListeningLease,
  requireActiveLeaseV2Authority,
  requireLeaseV2ForAskWrite,
  startListeningHeartbeat,
  type ListeningHeartbeatHandle,
  type ListeningShutdownEventSource,
} from "./listening.js";
import {
  safeErrorMessage,
  sanitizeAgentResponseData,
  sanitizeSensitiveData,
} from "./redaction.js";
import {
  listenerRegistrationBody,
  listenerRenewalBody,
  listenerTakeoverRequested,
} from "./thread-binding.js";
import {
  wakeCapabilityClientConfig,
  wakeCapabilityLocalFence,
} from "./wake-capability.js";

const server = new McpServer({
  name: "voice-agent-bridge",
  version: "0.1.0",
});

let listeningHeartbeat: ListeningHeartbeatHandle | undefined;
let activeAskConsumers = 0;
const enqueueAskClaim = createAskClaimQueue();

function waitForClaimPoll(milliseconds: number | undefined): Promise<void> {
  if (!milliseconds) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function setAskConsumerActive(active: boolean): void {
  activeAskConsumers = Math.max(0, activeAskConsumers + (active ? 1 : -1));
  listeningHeartbeat?.setConsumerActive(activeAskConsumers > 0);
}

function text(data: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(sanitizeSensitiveData(data), null, 2) ?? "null",
      },
    ],
  };
}

function agentText(data: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(sanitizeAgentResponseData(data), null, 2) ?? "null",
      },
    ],
  };
}

function errText(err: unknown) {
  const rawMessage =
    agentAuthFailureMessage(err) ??
    agentCredentialBindHint() ??
    (err instanceof Error ? err.message : String(err));
  const message = safeErrorMessage(rawMessage);
  return {
    isError: true as const,
    content: [{ type: "text" as const, text: message }],
  };
}

function requireMcpLeaseAuthority(): void {
  requireActiveLeaseV2Authority(listeningHeartbeat?.status());
}

function requireMcpLeaseForAskWrite(askBearing: boolean): void {
  requireLeaseV2ForAskWrite(listeningHeartbeat?.status(), askBearing);
}

server.registerTool(
  "create_or_resume_session",
  {
    title: "Create or resume session",
    description:
      "Create or resume a bridge session when a chat starts using a skill_id. Session is created by this call.",
    inputSchema: {
      skill_id: z.string().describe("Skill id, e.g. deploy.result or phone.ask"),
      session_id: z.string().optional().describe("Resume if still open for this agent"),
      idempotency_key: z.string().min(1).optional(),
      chat_id: z.string().optional(),
      title: z.string().optional(),
      facts: z.record(z.unknown()).optional(),
      metadata: z.record(z.unknown()).optional(),
    },
  },
  async (args) => {
    try {
      return text(await api("/v1/sessions", { method: "POST", json: args }));
    } catch (e) {
      return errText(e);
    }
  },
);

server.registerTool(
  "get_user_asks",
  {
    title: "Get user voice asks",
    description:
      "Poll hold-to-speak asks from the iPhone under an active lease-v2 listener. Claim credentials remain inside MCP and are attached automatically to phone.ask requests. Each ask includes its transcript, durable session_id, ask_id, client_turn_id, turn_sequence, and recent context_messages. Answer on that exact session with report_event so the phone can speak the response. Legacy listeners are rejected here and are drain-only through the CLI read path.",
    inputSchema: {
      wait_ms: z.number().int().min(0).max(30_000).optional(),
    },
  },
  async ({ wait_ms }) => {
    try {
      requireMcpLeaseAuthority();
      setAskConsumerActive(true);
      await waitForClaimPoll(wait_ms);
      const trackedResponse = await enqueueAskClaim(async () => {
        requireMcpLeaseAuthority();
        const response = await claimAgentAsks(
          (path, init) => api(path, init),
        );
        requireMcpLeaseAuthority();
        return trackAgentAskResponse(response);
      });
      return agentText(trackedResponse);
    } catch (e) {
      return errText(e);
    } finally {
      setAskConsumerActive(false);
    }
  },
);

server.registerTool(
  "update_progress",
  {
    title: "Update progress",
    description:
      "Mirror progress/status to the bridge. NEVER triggers phone push — use report_event when the user must be notified.",
    inputSchema: {
      session_id: z.string(),
      status: z.enum(["started", "running", "blocked", "succeeded", "failed", "cancelled"]),
      message: z.string().max(280).optional(),
      percent: z.number().min(0).max(100).optional(),
      facts: z.record(z.unknown()).optional(),
      ask_id: z.string().optional().describe("Optional phone.ask id when a session has multiple asks"),
    },
  },
  async ({ session_id, ask_id, ...body }) => {
    let preparedAskId = ask_id;
    let reservationToken: string | undefined;
    try {
      requireMcpLeaseForAskWrite(
        Boolean(ask_id) || hasUnsettledAskClaimForSession(session_id),
      );
      const prepared = beginPhoneAskProgressRequest(session_id, body, ask_id);
      preparedAskId = prepared.askId ?? ask_id;
      reservationToken = prepared.reservationToken;
      const result = await api(
        `/v1/sessions/${encodeURIComponent(session_id)}/progress`, {
          method: "POST",
          json: prepared.body,
        },
      );
      if (prepared.askId) {
        completePhoneAskProgressRequest(
          session_id,
          prepared.askId,
          reservationToken,
        );
      }
      return text(result);
    } catch (e) {
      markPhoneAskClaimFailure(
        session_id,
        preparedAskId,
        e,
        reservationToken,
      );
      return errText(e);
    }
  },
);

server.registerTool(
  "report_event",
  {
    title: "Report event",
    description:
      "Agent response/event. Use info with in_reply_to_ask_id for an ordinary voice answer; the phone speaks its summary. A claimed Ask answer binds its canonical payload and idempotency key before delivery; only one identical retry is allowed after a transient or ambiguous failure. MAY push for needs_user (always), or succeeded/failed when actions are present or force_push. needs_user requires actions. High-risk work still requires the confirmation gate.",
    inputSchema: {
      session_id: z.string(),
      status: z.enum(["info", "needs_user", "succeeded", "failed"]),
      idempotency_key: z.string().min(1),
      ask_id: z.string().optional().describe("Canonical phone.ask id"),
      in_reply_to_ask_id: z.string().optional(),
      summary: z.string().max(280).optional(),
      facts: z.record(z.unknown()).optional(),
      actions: z
        .array(z.string())
        .optional()
        .describe('Skill action ids, e.g. ["rollback","ack"]'),
      force_push: z.boolean().optional(),
    },
  },
  async ({ session_id, ask_id, in_reply_to_ask_id, ...body }) => {
    const askHint = ask_id ?? in_reply_to_ask_id;
    try {
      requireMcpLeaseForAskWrite(
        Boolean(askHint) || hasUnsettledAskClaimForSession(session_id),
      );
      const result = await executeDirectPhoneAskAnswer(
        session_id,
        body,
        askHint,
        (preparedBody) =>
          api(`/v1/sessions/${encodeURIComponent(session_id)}/events`, {
            method: "POST",
            json: preparedBody,
          }),
      );
      return text(
        result,
      );
    } catch (e) {
      return errText(e);
    }
  },
);

server.registerTool(
  "get_pending_actions",
  {
    title: "Get pending actions",
    description:
      "Fetch user-approved queued actions for this agent (or a session). claim defaults true.",
    inputSchema: {
      session_id: z.string().optional(),
      claim: z.boolean().optional().describe("Claim actions for exclusive processing (default true)"),
      wait_ms: z.number().int().min(0).max(30_000).optional(),
    },
  },
  async ({ session_id, claim, wait_ms }) => {
    try {
      const q = new URLSearchParams({ claim: claim === false ? "false" : "true" });
      if (wait_ms !== undefined) q.set("wait_ms", String(wait_ms));
      const path = session_id
        ? `/v1/sessions/${encodeURIComponent(session_id)}/actions/pending?${q}`
        : `/v1/agents/me/actions/pending?${q}`;
      return text(await api(path));
    } catch (e) {
      return errText(e);
    }
  },
);

server.registerTool(
  "submit_action_result",
  {
    title: "Submit action result",
    description: "Report result after executing a claimed action. Does not push.",
    inputSchema: {
      action_id: z.string(),
      ok: z.boolean(),
      message: z.string().optional(),
      output: z.record(z.unknown()).optional(),
    },
  },
  async ({ action_id, ...body }) => {
    try {
      return text(
        await api(`/v1/actions/${encodeURIComponent(action_id)}/result`, {
          method: "POST",
          json: body,
        }),
      );
    } catch (e) {
      return errText(e);
    }
  },
);

export type McpStdioLifecycleTransport = {
  onclose?: () => void;
  onerror?: (error: Error) => void;
};

export async function runMcpStdioListeningLifecycle(options: {
  heartbeat: ListeningHeartbeatHandle;
  transport: McpStdioLifecycleTransport;
  processEvents: ListeningShutdownEventSource;
  inputEvents: ListeningShutdownEventSource;
  close: () => void | Promise<void>;
  onError?: (error: unknown) => void;
}): Promise<void> {
  let fatalError: Error | undefined;
  const previousClose = options.transport.onclose;
  const previousError = options.transport.onerror;
  const shutdown = createListeningShutdownController(options.heartbeat, {
    bindings: [
      { source: options.processEvents, event: "SIGINT", reason: "sigint" },
      { source: options.processEvents, event: "SIGTERM", reason: "sigterm" },
      { source: options.inputEvents, event: "end", reason: "stdin_end" },
      { source: options.inputEvents, event: "close", reason: "stdin_close" },
    ],
    afterStop: () => options.close(),
    onError: options.onError,
  });
  options.transport.onclose = () => {
    try {
      previousClose?.();
    } finally {
      void shutdown.stop("stdio_close");
    }
  };
  options.transport.onerror = (error) => {
    try {
      previousError?.(error);
    } finally {
      fatalError = error;
      void shutdown.stop("stdio_fatal");
    }
  };

  try {
    await shutdown.wait();
    if (fatalError) throw fatalError;
  } finally {
    await shutdown.stop(fatalError ? "stdio_fatal" : "stdio_return");
    options.transport.onclose = previousClose;
    options.transport.onerror = previousError;
  }
}

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // This starts asynchronously after stdio is live, so registration never
  // blocks MCP discovery. Lease-v2 renewals cannot reacquire after fencing.
  const wakeCapability = wakeCapabilityClientConfig();
  const inheritedFence = wakeCapability
    ? wakeCapabilityLocalFence(wakeCapability)
    : undefined;
  listeningHeartbeat = startListeningHeartbeat(
    {
      acquire: (takeover) =>
        api(listeningRegistrationPath(), {
          method: "POST",
          json: listenerRegistrationBody(takeover),
          timeoutMs: 5_000,
        }),
      renew: (lease) =>
        api(listeningHeartbeatPath(), {
          method: "POST",
          json: listenerRenewalBody(lease),
          timeoutMs: 5_000,
        }),
      release: (lease) =>
        releaseListeningLease(
          (path, init) =>
            api(path, {
              ...init,
              timeoutMs: 5_000,
            }),
          lease,
        ),
    },
    {
      takeover: inheritedFence ? false : listenerTakeoverRequested(),
      inheritedFence: inheritedFence ?? undefined,
    },
  );
  const heartbeat = listeningHeartbeat;
  try {
    await runMcpStdioListeningLifecycle({
      heartbeat,
      transport,
      processEvents: process,
      inputEvents: process.stdin,
      close: () => server.close(),
      onError: (error) => console.error(safeErrorMessage(error)),
    });
  } finally {
    if (listeningHeartbeat === heartbeat) listeningHeartbeat = undefined;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void main().catch((err: unknown) => {
    console.error(safeErrorMessage(err instanceof Error ? err.stack ?? err.message : err));
    process.exitCode = 1;
  });
}
