import { createHash, randomBytes, randomInt } from "node:crypto";
import bcrypt from "bcryptjs";
import type { Context, Next } from "hono";
import { SignJWT, jwtVerify } from "jose";
import { nanoid } from "nanoid";
import { config } from "./config.js";
import { getDb, nowIso } from "./db.js";

const encoder = new TextEncoder();

export type UserAuth = { userId: string; email: string };
export type AgentAuth = { agentId: string; userId: string; label: string };
export type AuthTokens = {
  user_id: string;
  token: string;
  refresh_token: string;
  expires_in: number;
};

export type AppVariables = {
  user?: UserAuth;
  agent?: AgentAuth;
};

export function hashApiKey(apiKey: string): string {
  return createHash("sha256").update(apiKey).digest("hex");
}

export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, 10);
}

export async function verifyPassword(password: string, hash: string): Promise<boolean> {
  return bcrypt.compare(password, hash);
}

export async function signUserToken(userId: string, email: string): Promise<string> {
  return new SignJWT({ email, typ: "user" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${config.accessTokenTtlSec}s`)
    .sign(encoder.encode(config.jwtSecret));
}

function hashRefreshToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function mintRefreshToken(): string {
  return `vbr_${randomBytes(32).toString("base64url")}`;
}

/** Issue a short-lived access token and a one-time-rotatable refresh token. */
export async function issueUserAuth(
  userId: string,
  email: string,
  metadata: { userAgent?: string | null; ipAddress?: string | null } = {},
): Promise<AuthTokens> {
  const token = await signUserToken(userId, email);
  const refreshToken = mintRefreshToken();
  const createdAt = nowIso();
  getDb()
    .prepare(
      `INSERT INTO refresh_tokens
       (id, user_id, token_hash, expires_at, revoked_at, last_used_at, user_agent, ip_address, created_at)
       VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, ?)`,
    )
    .run(
      newId("rft"),
      userId,
      hashRefreshToken(refreshToken),
      new Date(Date.now() + config.refreshTokenTtlSec * 1000).toISOString(),
      metadata.userAgent ?? null,
      metadata.ipAddress ?? null,
      createdAt,
    );
  return {
    user_id: userId,
    token,
    refresh_token: refreshToken,
    expires_in: config.accessTokenTtlSec,
  };
}

/** Rotate a refresh token so a stolen token cannot be reused indefinitely. */
export async function rotateRefreshToken(
  refreshToken: string,
  metadata: { userAgent?: string | null; ipAddress?: string | null } = {},
): Promise<AuthTokens> {
  const database = getDb();
  const now = nowIso();
  const row = database
    .prepare(
      `SELECT rt.id, rt.user_id, rt.expires_at, rt.revoked_at, u.email
       FROM refresh_tokens rt JOIN users u ON u.id = rt.user_id
       WHERE rt.token_hash = ?`,
    )
    .get(hashRefreshToken(refreshToken)) as
    | { id: string; user_id: string; expires_at: string; revoked_at: string | null; email: string }
    | undefined;
  if (!row || row.revoked_at || new Date(row.expires_at).getTime() <= Date.now()) {
    throw new Error("Invalid or expired refresh token");
  }

  const result = database
    .prepare(
      `UPDATE refresh_tokens SET revoked_at = ?, last_used_at = ?
       WHERE id = ? AND revoked_at IS NULL`,
    )
    .run(now, now, row.id);
  if (result.changes === 0) {
    throw new Error("Refresh token was already rotated");
  }
  // Claim the old token before issuing the next one. Concurrent refreshes
  // therefore produce exactly one successor instead of orphaning multiple
  // valid refresh tokens.
  return issueUserAuth(row.user_id, row.email, metadata);
}

export function revokeRefreshToken(refreshToken: string): void {
  getDb()
    .prepare("UPDATE refresh_tokens SET revoked_at = ?, last_used_at = ? WHERE token_hash = ? AND revoked_at IS NULL")
    .run(nowIso(), nowIso(), hashRefreshToken(refreshToken));
}

export async function verifyUserToken(token: string): Promise<UserAuth> {
  const { payload } = await jwtVerify(token, encoder.encode(config.jwtSecret));
  if (payload.typ !== "user" || typeof payload.sub !== "string") {
    throw new Error("invalid token");
  }
  return {
    userId: payload.sub,
    email: typeof payload.email === "string" ? payload.email : "",
  };
}

export function mintApiKey(): string {
  return `vak_${nanoid(32)}`;
}

export function mintPairingCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}

export function newId(prefix: string): string {
  return `${prefix}_${nanoid(16)}`;
}

export async function requireUser(c: Context<{ Variables: AppVariables }>, next: Next) {
  const header = c.req.header("authorization") ?? c.req.header("Authorization");
  if (!header?.startsWith("Bearer ")) {
    return c.json({ error: "unauthorized", message: "Missing Bearer token" }, 401);
  }
  try {
    const user = await verifyUserToken(header.slice(7).trim());
    const row = getDb().prepare("SELECT id FROM users WHERE id = ?").get(user.userId) as
      | { id: string }
      | undefined;
    if (!row) {
      return c.json({ error: "unauthorized", message: "User not found" }, 401);
    }
    c.set("user", user);
    await next();
  } catch {
    return c.json({ error: "unauthorized", message: "Invalid token" }, 401);
  }
}

export async function requireAgent(c: Context<{ Variables: AppVariables }>, next: Next) {
  const key = c.req.header("x-agent-key") ?? c.req.header("X-Agent-Key");
  if (!key) {
    return c.json({ error: "unauthorized", message: "Missing X-Agent-Key" }, 401);
  }
  const row = getDb()
    .prepare("SELECT id, user_id, label FROM agents WHERE api_key_hash = ?")
    .get(hashApiKey(key)) as { id: string; user_id: string; label: string } | undefined;
  if (!row) {
    return c.json({ error: "unauthorized", message: "Invalid agent key" }, 401);
  }
  c.set("agent", { agentId: row.id, userId: row.user_id, label: row.label });
  await next();
}

/** Read-only resources that can be consumed by either the phone user or its agent. */
export async function requireUserOrAgent(c: Context<{ Variables: AppVariables }>, next: Next) {
  const authorization = c.req.header("authorization") ?? c.req.header("Authorization");
  if (authorization?.startsWith("Bearer ")) {
    try {
      const user = await verifyUserToken(authorization.slice(7).trim());
      const row = getDb().prepare("SELECT id FROM users WHERE id = ?").get(user.userId);
      if (row) {
        c.set("user", user);
        return next();
      }
    } catch {
      // Fall through to the uniform unauthorized response below.
    }
  }
  const key = c.req.header("x-agent-key") ?? c.req.header("X-Agent-Key");
  if (key) {
    const row = getDb()
      .prepare("SELECT id, user_id, label FROM agents WHERE api_key_hash = ?")
      .get(hashApiKey(key)) as { id: string; user_id: string; label: string } | undefined;
    if (row) {
      c.set("agent", { agentId: row.id, userId: row.user_id, label: row.label });
      return next();
    }
  }
  return c.json({ error: "unauthorized", message: "Valid user or agent credentials required" }, 401);
}

export function createAgentForUser(
  userId: string,
  label: string,
  hostLabel?: string | null,
): { agent: Record<string, unknown>; api_key: string } {
  const database = getDb();
  const id = newId("agt");
  const apiKey = mintApiKey();
  const createdAt = nowIso();
  database
    .prepare(
      `INSERT INTO agents (id, user_id, label, host_label, api_key_hash, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .run(id, userId, label, hostLabel ?? null, hashApiKey(apiKey), createdAt);

  return {
    api_key: apiKey,
    agent: {
      agent_id: id,
      user_id: userId,
      label,
      host_label: hostLabel ?? null,
      created_at: createdAt,
    },
  };
}

export function rotateAgentKeyForUser(
  userId: string,
  agentId: string,
): { agent: Record<string, unknown>; api_key: string } {
  const database = getDb();
  const row = database
    .prepare("SELECT id, user_id, label, host_label, created_at FROM agents WHERE id = ? AND user_id = ?")
    .get(agentId, userId) as
    | { id: string; user_id: string; label: string; host_label: string | null; created_at: string }
    | undefined;
  if (!row) throw Object.assign(new Error("Agent not found"), { status: 404 });
  const apiKey = mintApiKey();
  database
    .prepare("UPDATE agents SET api_key_hash = ? WHERE id = ? AND user_id = ?")
    .run(hashApiKey(apiKey), agentId, userId);
  return {
    api_key: apiKey,
    agent: {
      agent_id: row.id,
      user_id: row.user_id,
      label: row.label,
      host_label: row.host_label,
      created_at: row.created_at,
    },
  };
}
