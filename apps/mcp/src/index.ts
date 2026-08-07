#!/usr/bin/env node
/**
 * Voice Agent Bridge MCP server (stdio).
 * Tools call BRIDGE_API_URL with X-Agent-Key from BRIDGE_AGENT_KEY.
 *
 * Push: update_progress NEVER pushes; report_event MAY push.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { api } from "./client.js";

const server = new McpServer({
  name: "voice-agent-bridge",
  version: "0.1.0",
});

function text(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

function errText(err: unknown) {
  const message = err instanceof Error ? err.message : String(err);
  return {
    isError: true as const,
    content: [{ type: "text" as const, text: message }],
  };
}

server.registerTool(
  "create_or_resume_session",
  {
    title: "Create or resume session",
    description:
      "Create or resume a bridge session when a chat starts using a skill_id. Session is created by this call.",
    inputSchema: {
      skill_id: z.string().describe("Skill id, e.g. deploy.result"),
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
    },
  },
  async ({ session_id, ...body }) => {
    try {
      return text(
        await api(`/v1/sessions/${encodeURIComponent(session_id)}/progress`, {
          method: "POST",
          json: body,
        }),
      );
    } catch (e) {
      return errText(e);
    }
  },
);

server.registerTool(
  "report_event",
  {
    title: "Report event",
    description:
      "Agent-decided event. MAY push for needs_user (always), or succeeded/failed when actions are present or force_push. needs_user requires actions (skill action id strings). Center does not guess needs_user.",
    inputSchema: {
      session_id: z.string(),
      status: z.enum(["needs_user", "succeeded", "failed"]),
      idempotency_key: z.string().min(1),
      summary: z.string().max(280).optional(),
      facts: z.record(z.unknown()).optional(),
      actions: z
        .array(z.string())
        .optional()
        .describe('Skill action ids, e.g. ["rollback","ack"]'),
      force_push: z.boolean().optional(),
    },
  },
  async ({ session_id, ...body }) => {
    try {
      return text(
        await api(`/v1/sessions/${encodeURIComponent(session_id)}/events`, {
          method: "POST",
          json: body,
        }),
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

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.stack ?? err.message : String(err));
  process.exit(1);
});
