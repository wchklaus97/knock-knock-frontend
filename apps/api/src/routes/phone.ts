import { Hono } from "hono";
import { z } from "zod";
import { newId, requireUser, type AppVariables } from "../auth.js";
import { listAuditForSession } from "../audit.js";
import { getDb, nowIso } from "../db.js";
import { listPhoneSessions, phoneConfirm, phoneReply } from "../sessions.js";

const phoneRoutes = new Hono<{ Variables: AppVariables }>();

function httpError(err: unknown): { status: number; message: string } {
  if (err && typeof err === "object" && "status" in err && "message" in err) {
    const e = err as { status: number; message: string };
    return { status: e.status || 500, message: e.message };
  }
  return { status: 500, message: err instanceof Error ? err.message : "Internal error" };
}

phoneRoutes.get("/sessions", requireUser, async (c) => {
  const user = c.get("user")!;
  const requestedLimit = Number(c.req.query("limit") ?? 100);
  const limit = Number.isFinite(requestedLimit) ? requestedLimit : 100;
  return c.json({ sessions: listPhoneSessions(user.userId, limit) });
});

phoneRoutes.get("/sessions/:id/history", requireUser, async (c) => {
  const user = c.get("user")!;
  const sessionId = c.req.param("id") ?? "";
  const requestedLimit = Number(c.req.query("limit") ?? 100);
  const limit = Number.isFinite(requestedLimit) ? requestedLimit : 100;
  const history = listAuditForSession(user.userId, sessionId, limit);
  if (history.length === 0) {
    const exists = getDb()
      .prepare("SELECT id FROM sessions WHERE id = ? AND user_id = ?")
      .get(sessionId, user.userId);
    if (!exists) return c.json({ error: "not_found", message: "Session not found" }, 404);
  }
  return c.json({ entries: history });
});

phoneRoutes.post("/devices", requireUser, async (c) => {
  const body = z
    .object({
      platform: z.string().min(1),
      push_token: z.string().optional(),
      locale: z.string().optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const user = c.get("user")!;
  const database = getDb();
  const now = nowIso();
  // Prefer updating the latest device row for this platform so APNs token refreshes stick.
  const existing = database
    .prepare(
      `SELECT id FROM devices WHERE user_id = ? AND platform = ? ORDER BY updated_at DESC LIMIT 1`,
    )
    .get(user.userId, body.data.platform) as { id: string } | undefined;

  let deviceId: string;
  if (existing) {
    deviceId = existing.id;
    database
      .prepare(`UPDATE devices SET push_token = ?, locale = ?, updated_at = ? WHERE id = ?`)
      .run(body.data.push_token ?? null, body.data.locale ?? null, now, deviceId);
  } else {
    deviceId = newId("dev");
    database
      .prepare(
        `INSERT INTO devices (id, user_id, platform, push_token, locale, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        deviceId,
        user.userId,
        body.data.platform,
        body.data.push_token ?? null,
        body.data.locale ?? null,
        now,
        now,
      );
  }

  return c.json({
    device_id: deviceId,
    platform: body.data.platform,
    push_token: body.data.push_token ?? null,
    locale: body.data.locale ?? null,
  });
});

phoneRoutes.post("/sessions/:id/reply", requireUser, async (c) => {
  const body = z
    .object({
      action_key: z.string().min(1),
      utterance: z.string().nullable().optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const user = c.get("user")!;
  const sessionId = c.req.param("id")!;
  try {
    const result = phoneReply({
      userId: user.userId,
      sessionId,
      actionKey: body.data.action_key,
      utterance: body.data.utterance,
    });
    return c.json(result);
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "reply_error", message: e.message }, e.status as 400);
  }
});

phoneRoutes.post("/sessions/:id/confirm", requireUser, async (c) => {
  const body = z
    .object({
      action_id: z.string().min(1),
      confirm: z.boolean(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const user = c.get("user")!;
  const sessionId = c.req.param("id")!;
  try {
    const result = phoneConfirm({
      userId: user.userId,
      sessionId,
      actionId: body.data.action_id,
      confirm: body.data.confirm,
    });
    return c.json(result);
  } catch (err) {
    const e = httpError(err);
    return c.json({ error: "confirm_error", message: e.message }, e.status as 400);
  }
});

export { phoneRoutes };
