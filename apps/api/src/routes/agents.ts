import { Hono } from "hono";
import { z } from "zod";
import {
  createAgentForUser,
  requireAgent,
  requireUser,
  rotateAgentKeyForUser,
  type AppVariables,
} from "../auth.js";
import { recordAudit } from "../audit.js";
import { getDb } from "../db.js";
import { actionToApi, waitForPendingActions } from "../sessions.js";

const agentsRoutes = new Hono<{ Variables: AppVariables }>();

agentsRoutes.post("/", requireUser, async (c) => {
  const body = z
    .object({
      label: z.string().min(1),
      host_label: z.string().optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const user = c.get("user")!;
  const created = createAgentForUser(user.userId, body.data.label, body.data.host_label);
  recordAudit({ action: "agent.create", userId: user.userId, agentId: created.agent.agent_id as string });
  return c.json(created, 201);
});

agentsRoutes.get("/", requireUser, async (c) => {
  const user = c.get("user")!;
  const rows = getDb()
    .prepare(
      `SELECT id, user_id, label, host_label, created_at FROM agents WHERE user_id = ? ORDER BY created_at DESC`,
    )
    .all(user.userId) as Array<{
    id: string;
    user_id: string;
    label: string;
    host_label: string | null;
    created_at: string;
  }>;
  return c.json({
    agents: rows.map((r) => ({
      agent_id: r.id,
      user_id: r.user_id,
      label: r.label,
      host_label: r.host_label,
      created_at: r.created_at,
    })),
  });
});

agentsRoutes.post("/:id/rotate-key", requireUser, async (c) => {
  const user = c.get("user")!;
  const agentId = c.req.param("id") ?? "";
  try {
    const rotated = rotateAgentKeyForUser(user.userId, agentId);
    recordAudit({ action: "agent.rotate_key", userId: user.userId, agentId });
    return c.json(rotated);
  } catch (error) {
    const status = error && typeof error === "object" && "status" in error
      ? Number((error as { status: unknown }).status)
      : 500;
    return c.json({ error: status === 404 ? "not_found" : "internal_error", message: error instanceof Error ? error.message : "Unable to rotate key" }, (status || 500) as 400 | 404 | 500);
  }
});

agentsRoutes.get("/me/actions/pending", requireAgent, async (c) => {
  const agent = c.get("agent")!;
  const claim = ["1", "true", "yes"].includes((c.req.query("claim") ?? "true").toLowerCase());
  const waitMs = Number(c.req.query("wait_ms") ?? 0);
  const actions = await waitForPendingActions({
    agentId: agent.agentId,
    claim,
    waitMs: Number.isFinite(waitMs) ? waitMs : 0,
  });
  return c.json({ actions: actions.map(actionToApi) });
});

export { agentsRoutes };
