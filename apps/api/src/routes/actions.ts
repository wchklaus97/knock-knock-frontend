import { Hono } from "hono";
import { z } from "zod";
import { requireAgent, type AppVariables } from "../auth.js";
import { submitActionResult } from "../sessions.js";

const actionsRoutes = new Hono<{ Variables: AppVariables }>();

function httpError(err: unknown): { status: number; message: string } {
  if (err && typeof err === "object" && "status" in err && "message" in err) {
    const e = err as { status: number; message: string };
    return { status: e.status || 500, message: e.message };
  }
  return { status: 500, message: err instanceof Error ? err.message : "Internal error" };
}

actionsRoutes.post("/:action_id/result", requireAgent, async (c) => {
  const body = z
    .object({
      ok: z.boolean(),
      message: z.string().optional(),
      output: z.record(z.unknown()).optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const agent = c.get("agent")!;
  const actionId = c.req.param("action_id")!;
  try {
    const action = submitActionResult({
      agentId: agent.agentId,
      actionId,
      ok: body.data.ok,
      message: body.data.message,
      output: body.data.output,
    });
    return c.json(action);
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "action_error", message: e.message }, e.status as 400);
  }
});

export { actionsRoutes };
