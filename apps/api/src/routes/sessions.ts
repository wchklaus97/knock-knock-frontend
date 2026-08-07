import { Hono } from "hono";
import { z } from "zod";
import {
  hashApiKey,
  requireAgent,
  verifyUserToken,
  type AppVariables,
} from "../auth.js";
import { getDb } from "../db.js";
import {
  actionToApi,
  createOrResumeSession,
  getSessionRow,
  reportEvent,
  sessionToApi,
  updateProgress,
  waitForPendingActions,
} from "../sessions.js";

const sessionsRoutes = new Hono<{ Variables: AppVariables }>();

function httpError(err: unknown): { status: number; message: string } {
  if (err && typeof err === "object" && "status" in err && "message" in err) {
    const e = err as { status: number; message: string };
    return { status: e.status || 500, message: e.message };
  }
  return { status: 500, message: err instanceof Error ? err.message : "Internal error" };
}

sessionsRoutes.post("/", requireAgent, async (c) => {
  const body = z
    .object({
      skill_id: z.string().min(1),
      session_id: z.string().optional(),
      idempotency_key: z.string().optional(),
      title: z.string().optional(),
      chat_id: z.string().optional(),
      facts: z.record(z.unknown()).optional(),
      metadata: z.record(z.unknown()).optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const agent = c.get("agent")!;
  try {
    const row = createOrResumeSession({
      agentId: agent.agentId,
      userId: agent.userId,
      skillId: body.data.skill_id,
      sessionId: body.data.session_id,
      idempotencyKey: body.data.idempotency_key,
      title: body.data.title,
      chatId: body.data.chat_id,
      facts: body.data.facts,
      metadata: body.data.metadata,
    });
    return c.json(sessionToApi(row), 201);
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "session_error", message: e.message }, e.status as 400);
  }
});

sessionsRoutes.get("/:id", async (c) => {
  const id = c.req.param("id")!;
  const row = getSessionRow(id);
  if (!row) return c.json({ error: "not_found", message: "Session not found" }, 404);

  const agentKey = c.req.header("x-agent-key") ?? c.req.header("X-Agent-Key");
  const authHeader = c.req.header("authorization") ?? c.req.header("Authorization");

  if (agentKey) {
    const agent = getDb()
      .prepare("SELECT id FROM agents WHERE api_key_hash = ?")
      .get(hashApiKey(agentKey)) as { id: string } | undefined;
    if (!agent || agent.id !== row.agent_id) {
      return c.json({ error: "forbidden", message: "Not your session" }, 403);
    }
    return c.json(sessionToApi(row));
  }

  if (authHeader?.startsWith("Bearer ")) {
    try {
      const user = await verifyUserToken(authHeader.slice(7).trim());
      if (user.userId !== row.user_id) {
        return c.json({ error: "forbidden", message: "Not your session" }, 403);
      }
      return c.json(sessionToApi(row));
    } catch {
      return c.json({ error: "unauthorized", message: "Invalid token" }, 401);
    }
  }

  return c.json({ error: "unauthorized", message: "Auth required" }, 401);
});

sessionsRoutes.post("/:id/progress", requireAgent, async (c) => {
  const body = z
    .object({
      status: z.enum(["started", "running", "blocked", "succeeded", "failed", "cancelled"]),
      message: z.string().optional(),
      percent: z.number().min(0).max(100).optional(),
      facts: z.record(z.unknown()).optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const agent = c.get("agent")!;
  const sessionId = c.req.param("id")!;
  const row = getSessionRow(sessionId);
  if (!row || row.agent_id !== agent.agentId) {
    return c.json({ error: "not_found", message: "Session not found" }, 404);
  }

  try {
    const updated = updateProgress(row, body.data);
    return c.json(sessionToApi(updated));
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "progress_error", message: e.message }, e.status as 400);
  }
});

sessionsRoutes.post("/:id/events", requireAgent, async (c) => {
  const body = z
    .object({
      status: z.enum(["info", "needs_user", "succeeded", "failed"]),
      summary: z.string().max(280).optional(),
      facts: z.record(z.unknown()).optional(),
      actions: z
        .array(
          z.union([
            z.string(),
            z.object({
              id: z.string(),
              risk: z.enum(["low", "medium", "high", "destructive"]).optional(),
              confirm: z.boolean().optional(),
              title: z.string().optional(),
              payload: z.record(z.unknown()).optional(),
            }),
          ]),
        )
        .optional(),
      idempotency_key: z.string().min(1),
      force_push: z.boolean().optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const agent = c.get("agent")!;
  const sessionId = c.req.param("id")!;
  const row = getSessionRow(sessionId);
  if (!row || row.agent_id !== agent.agentId) {
    return c.json({ error: "not_found", message: "Session not found" }, 404);
  }

  try {
    const result = reportEvent(row, {
      status: body.data.status,
      summary: body.data.summary,
      facts: body.data.facts,
      actions: body.data.actions,
      idempotencyKey: body.data.idempotency_key,
      forcePush: body.data.force_push,
    });
    return c.json(result);
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "event_error", message: e.message }, e.status as 400);
  }
});

sessionsRoutes.get("/:id/actions/pending", requireAgent, async (c) => {
  const agent = c.get("agent")!;
  const sessionId = c.req.param("id")!;
  const row = getSessionRow(sessionId);
  if (!row || row.agent_id !== agent.agentId) {
    return c.json({ error: "not_found", message: "Session not found" }, 404);
  }
  const claim = ["1", "true", "yes"].includes((c.req.query("claim") ?? "true").toLowerCase());
  const waitMs = Number(c.req.query("wait_ms") ?? 0);
  const actions = await waitForPendingActions({
    agentId: agent.agentId,
    sessionId: row.id,
    claim,
    waitMs: Number.isFinite(waitMs) ? waitMs : 0,
  });
  return c.json({ actions: actions.map(actionToApi) });
});

export { sessionsRoutes };
