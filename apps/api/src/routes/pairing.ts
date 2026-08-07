import { Hono } from "hono";
import { z } from "zod";
import {
  createAgentForUser,
  mintPairingCode,
  requireUser,
  type AppVariables,
} from "../auth.js";
import { recordAudit } from "../audit.js";
import { config } from "../config.js";
import { addSecondsIso, getDb, isExpired, nowIso } from "../db.js";

const pairingRoutes = new Hono<{ Variables: AppVariables }>();

pairingRoutes.post("/code", requireUser, async (c) => {
  const body = z
    .object({ ttl_sec: z.number().int().positive().max(3600).optional() })
    .safeParse((await c.req.json().catch(() => ({}))) ?? {});
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const user = c.get("user")!;
  const ttl = Math.min(body.data.ttl_sec ?? config.pairingTtlSec, 3600);
  const code = mintPairingCode();
  const createdAt = nowIso();
  const expiresAt = addSecondsIso(ttl);
  getDb()
    .prepare(
      `INSERT INTO pairing_codes (code, user_id, expires_at, claimed_at, created_at)
       VALUES (?, ?, ?, NULL, ?)`,
    )
    .run(code, user.userId, expiresAt, createdAt);
  recordAudit({ action: "pairing.create", userId: user.userId, metadata: { expires_at: expiresAt } });
  return c.json({ code, expires_at: expiresAt }, 201);
});

pairingRoutes.post("/claim", async (c) => {
  const body = z
    .object({
      code: z.string().min(4).max(12),
      label: z.string().min(1),
      host_label: z.string().optional(),
    })
    .safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const database = getDb();
  const code = body.data.code.trim();
  const claimedAt = nowIso();

  // Claim first inside the same write transaction as agent creation. This
  // prevents two concurrent CLI/Cursor claims from both receiving keys for
  // the same one-time pairing code.
  const outcome = database.transaction(() => {
    const claimed = database
      .prepare(
        `UPDATE pairing_codes
         SET claimed_at = ?
         WHERE code = ? AND claimed_at IS NULL AND expires_at > ?`,
      )
      .run(claimedAt, code, claimedAt);

    if (claimed.changes === 0) {
      const row = database
        .prepare(`SELECT user_id, expires_at, claimed_at FROM pairing_codes WHERE code = ?`)
        .get(code) as
        | { user_id: string; expires_at: string; claimed_at: string | null }
        | undefined;
      if (!row) return { kind: "not_found" as const };
      if (row.claimed_at) return { kind: "claimed" as const };
      if (isExpired(row.expires_at)) return { kind: "expired" as const };
      return { kind: "conflict" as const };
    }

    const row = database
      .prepare(`SELECT user_id FROM pairing_codes WHERE code = ?`)
      .get(code) as { user_id: string } | undefined;
    if (!row) return { kind: "not_found" as const };

    const created = createAgentForUser(row.user_id, body.data.label, body.data.host_label);
    recordAudit({
      action: "pairing.claim",
      userId: row.user_id,
      agentId: created.agent.agent_id as string,
      metadata: { label: body.data.label, host_label: body.data.host_label ?? null },
    });
    return { kind: "created" as const, created };
  })();

  if (outcome.kind === "not_found") {
    return c.json({ error: "not_found", message: "Invalid pairing code" }, 404);
  }
  if (outcome.kind === "claimed") {
    return c.json({ error: "conflict", message: "Pairing code already claimed" }, 409);
  }
  if (outcome.kind === "expired") {
    return c.json({ error: "gone", message: "Pairing code expired" }, 410);
  }
  if (outcome.kind === "conflict") {
    return c.json({ error: "conflict", message: "Pairing code could not be claimed" }, 409);
  }

  return c.json(
    {
      agent_id: outcome.created.agent.agent_id,
      api_key: outcome.created.api_key,
      label: outcome.created.agent.label,
      agent: outcome.created.agent,
    },
    201,
  );
});

export { pairingRoutes };
