import { Hono } from "hono";
import type { Context } from "hono";
import { z } from "zod";
import {
  hashPassword,
  issueUserAuth,
  newId,
  revokeRefreshToken,
  rotateRefreshToken,
  verifyPassword,
  type AppVariables,
} from "../auth.js";
import { recordAudit } from "../audit.js";
import { getDb, nowIso } from "../db.js";

const authRoutes = new Hono<{ Variables: AppVariables }>();

const credsSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8).max(128),
});

authRoutes.post("/register", async (c) => {
  const body = credsSchema.safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const email = body.data.email.toLowerCase();
  const database = getDb();
  const existing = database.prepare("SELECT id FROM users WHERE email = ?").get(email);
  if (existing) {
    return c.json({ error: "conflict", message: "Email already registered" }, 409);
  }
  const userId = newId("usr");
  database
    .prepare(`INSERT INTO users (id, email, password_hash, created_at) VALUES (?, ?, ?, ?)`)
    .run(userId, email, await hashPassword(body.data.password), nowIso());
  const auth = await issueUserAuth(userId, email, requestMetadata(c));
  recordAudit({ action: "auth.register", userId, metadata: { email } });
  return c.json(auth, 201);
});

authRoutes.post("/login", async (c) => {
  const body = credsSchema.safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  const email = body.data.email.toLowerCase();
  const row = getDb()
    .prepare("SELECT id, password_hash FROM users WHERE email = ?")
    .get(email) as { id: string; password_hash: string } | undefined;
  if (!row || !(await verifyPassword(body.data.password, row.password_hash))) {
    return c.json({ error: "unauthorized", message: "Invalid credentials" }, 401);
  }
  const auth = await issueUserAuth(row.id, email, requestMetadata(c));
  recordAudit({ action: "auth.login", userId: row.id });
  return c.json(auth);
});

authRoutes.post("/refresh", async (c) => {
  const body = z.object({ refresh_token: z.string().min(20) }).safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  try {
    const auth = await rotateRefreshToken(body.data.refresh_token, requestMetadata(c));
    recordAudit({ action: "auth.refresh", userId: auth.user_id });
    return c.json(auth);
  } catch {
    return c.json({ error: "unauthorized", message: "Invalid or expired refresh token" }, 401);
  }
});

authRoutes.post("/logout", async (c) => {
  const body = z.object({ refresh_token: z.string().min(20) }).safeParse(await c.req.json());
  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }
  revokeRefreshToken(body.data.refresh_token);
  return c.json({ ok: true });
});

function requestMetadata(c: Context) {
  return {
    userAgent: c.req.header("user-agent") ?? null,
    ipAddress: c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
  };
}

export { authRoutes };
