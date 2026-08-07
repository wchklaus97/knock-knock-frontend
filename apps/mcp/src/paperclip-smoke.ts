#!/usr/bin/env node
/**
 * Local Paperclip boundary smoke.
 *
 * It exercises the governed stdio MCP connection and uses the phone API only
 * to simulate the already-authorized user tap. The important assertion is
 * that every step keeps the same bridge session_id.
 */
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const apiBase = (
  process.env.KNOCK_KNOCK_API_URL ??
  process.env.BRIDGE_API_URL ??
  "http://127.0.0.1:8787"
).replace(/\/+$/, "");
const email = process.env.PAPERCLIP_TEST_EMAIL ?? "e2e-1785931570@local.test";
const password = process.env.PAPERCLIP_TEST_PASSWORD ?? "password123";

type ToolText = { type: "text"; text: string };
function fail(message: string): never {
  throw new Error(message);
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) fail(message);
}

function parseTool(result: unknown): Record<string, any> {
  const outer = result as { isError?: boolean; content?: unknown[]; toolResult?: unknown };
  const raw = outer.toolResult && typeof outer.toolResult === "object"
    ? outer.toolResult as { isError?: boolean; content?: unknown[] }
    : outer;
  const content = raw.content ?? [];
  const textItems = content.filter((item): item is ToolText => {
    if (!item || typeof item !== "object") return false;
    const candidate = item as { type?: unknown; text?: unknown };
    return candidate.type === "text" && typeof candidate.text === "string";
  });
  if (raw.isError) {
    const message = textItems.map((item) => item.text).join("\n");
    fail(message || "MCP tool returned an error");
  }
  const text = textItems[0];
  if (!text) fail("MCP tool returned no text");
  return JSON.parse(text.text) as Record<string, any>;
}

async function jsonResponse(response: Response): Promise<Record<string, any>> {
  const body = (await response.json()) as Record<string, any>;
  if (!response.ok) fail(`${response.status} ${JSON.stringify(body)}`);
  return body;
}

const transport = new StdioClientTransport({
  command: "pnpm",
  args: ["--filter", "@vab/mcp", "dev"],
  cwd: root,
  env: {
    ...process.env,
    KNOCK_KNOCK_API_URL: apiBase,
    BRIDGE_API_URL: apiBase,
  },
});
const client = new Client({ name: "paperclip-same-session-smoke", version: "1.0.0" });

try {
  await client.connect(transport);
  const listed = await client.listTools();
  const toolNames = listed.tools.map((tool) => tool.name);
  assert(toolNames.length === 5, `expected 5 MCP tools, got ${toolNames.length}`);

  const runKey = `paperclip-smoke-${Date.now()}`;
  const created = parseTool(await client.callTool({
    name: "create_or_resume_session",
    arguments: {
      skill_id: "deploy.result",
      idempotency_key: runKey,
      chat_id: `${runKey}-chat`,
      title: "Paperclip same-session smoke",
    },
  }));
  const sessionId = created.session_id as string | undefined;
  assert(sessionId, "create_or_resume_session did not return session_id");

  const resumed = parseTool(await client.callTool({
    name: "create_or_resume_session",
    arguments: { skill_id: "deploy.result", session_id: sessionId },
  }));
  assert(resumed.session_id === sessionId, "resume returned a different session_id");

  const progress = parseTool(await client.callTool({
    name: "update_progress",
    arguments: { session_id: sessionId, status: "running", message: "Paperclip smoke in progress" },
  }));
  assert(progress.session_id === sessionId, "progress left the original session");

  const event = parseTool(await client.callTool({
    name: "report_event",
    arguments: {
      session_id: sessionId,
      status: "needs_user",
      idempotency_key: `${runKey}-needs-user`,
      facts: { service: "paperclip", status: "same-session check", env: "local" },
      actions: ["ack"],
    },
  }));
  assert(event.session?.session_id === sessionId && event.pushed === true, "needs_user lost the original session or push");

  const auth = await jsonResponse(await fetch(`${apiBase}/v1/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  }));
  const phoneReply = await jsonResponse(await fetch(`${apiBase}/v1/phone/sessions/${encodeURIComponent(sessionId)}/reply`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${auth.token}` },
    body: JSON.stringify({ action_key: "ack", utterance: "已知晓" }),
  }));
  assert(phoneReply.needs_confirm === false && phoneReply.session?.session_id === sessionId, "phone reply lost session binding");

  const pending = parseTool(await client.callTool({
    name: "get_pending_actions",
    arguments: { session_id: sessionId, claim: true, wait_ms: 3_000 },
  }));
  assert(pending.actions?.length === 1 && pending.actions[0].session_id === sessionId, "pending action was not bound to the same session");
  const actionId = pending.actions[0].action_id as string;

  const result = parseTool(await client.callTool({
    name: "submit_action_result",
    arguments: { action_id: actionId, ok: true, message: "Paperclip same-session smoke completed" },
  }));
  assert(result.action_id === actionId && result.status === "done", "result did not complete the claimed action");

  const retry = parseTool(await client.callTool({
    name: "submit_action_result",
    arguments: { action_id: actionId, ok: true, message: "retry should be idempotent" },
  }));
  assert(retry.action_id === actionId && retry.status === "done", "result retry was not idempotent");

  console.log(JSON.stringify({
    ok: true,
    toolCount: toolNames.length,
    sessionId,
    resumedSameSession: true,
    phoneReplyBound: true,
    actionId,
    resultStatus: result.status,
    retryStatus: retry.status,
  }, null, 2));
} finally {
  await client.close().catch(() => undefined);
}
