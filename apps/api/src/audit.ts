import { newId } from "./auth.js";
import { getDb, nowIso } from "./db.js";

export function recordAudit(input: {
  action: string;
  userId?: string | null;
  agentId?: string | null;
  sessionId?: string | null;
  metadata?: Record<string, unknown>;
}): void {
  try {
    getDb()
      .prepare(
        `INSERT INTO audit_logs
         (id, user_id, agent_id, session_id, action, metadata_json, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        newId("aud"),
        input.userId ?? null,
        input.agentId ?? null,
        input.sessionId ?? null,
        input.action,
        JSON.stringify(input.metadata ?? {}),
        nowIso(),
      );
  } catch (error) {
    // Auditing must never turn a successful user decision into a 500. The
    // process logger still makes a broken audit store visible to operators.
    console.error("[audit] write failed", error);
  }
}

export type AuditEntry = {
  audit_id: string;
  action: string;
  session_id: string | null;
  agent_id: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
};

export function listAuditForSession(userId: string, sessionId: string, limit = 100): AuditEntry[] {
  const safeLimit = Math.min(Math.max(1, Math.floor(limit)), 200);
  const rows = getDb()
    .prepare(
      `SELECT id, action, session_id, agent_id, metadata_json, created_at
       FROM audit_logs WHERE user_id = ? AND session_id = ?
       ORDER BY created_at ASC LIMIT ?`,
    )
    .all(userId, sessionId, safeLimit) as Array<{
    id: string;
    action: string;
    session_id: string | null;
    agent_id: string | null;
    metadata_json: string;
    created_at: string;
  }>;
  return rows.map((row) => ({
    audit_id: row.id,
    action: row.action,
    session_id: row.session_id,
    agent_id: row.agent_id,
    metadata: JSON.parse(row.metadata_json || "{}") as Record<string, unknown>,
    created_at: row.created_at,
  }));
}
