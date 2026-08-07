import { DatabaseSync } from "node:sqlite";
import { config } from "./config.js";

export type Db = DatabaseSync & {
  transaction<T>(fn: () => T): () => T;
};

let db: Db | null = null;

function withTransaction<T>(database: DatabaseSync, fn: () => T): () => T {
  return () => {
    database.exec("BEGIN");
    try {
      const result = fn();
      database.exec("COMMIT");
      return result;
    } catch (err) {
      try {
        database.exec("ROLLBACK");
      } catch {
        // ignore rollback errors
      }
      throw err;
    }
  };
}

export function getDb(): Db {
  if (!db) {
    const raw = new DatabaseSync(config.databasePath);
    raw.exec("PRAGMA journal_mode = WAL");
    raw.exec("PRAGMA foreign_keys = ON");
    migrate(raw);
    db = Object.assign(raw, {
      transaction<T>(fn: () => T) {
        return withTransaction(raw, fn);
      },
    }) as Db;
  }
  return db;
}

export function migrate(database: DatabaseSync = getDb()): void {
  database.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS refresh_tokens (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at TEXT NOT NULL,
      revoked_at TEXT,
      last_used_at TEXT,
      user_agent TEXT,
      ip_address TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS agents (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      label TEXT NOT NULL,
      host_label TEXT,
      api_key_hash TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS pairing_codes (
      code TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      expires_at TEXT NOT NULL,
      claimed_at TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS skills (
      skill_id TEXT PRIMARY KEY,
      template TEXT NOT NULL,
      facts_schema_json TEXT NOT NULL,
      actions_json TEXT NOT NULL,
      ttl_json TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      agent_id TEXT NOT NULL REFERENCES agents(id),
      user_id TEXT NOT NULL REFERENCES users(id),
      skill_id TEXT NOT NULL REFERENCES skills(skill_id),
      state TEXT NOT NULL,
      progress_status TEXT,
      progress_message TEXT,
      progress_percent REAL,
      title TEXT,
      chat_id TEXT,
      summary_text TEXT,
      voice_script TEXT,
      facts_json TEXT NOT NULL DEFAULT '{}',
      available_actions_json TEXT,
      idempotency_key TEXT,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(agent_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      status TEXT NOT NULL,
      idempotency_key TEXT,
      payload_json TEXT NOT NULL,
      pushed INTEGER NOT NULL DEFAULT 0,
      summary_text TEXT,
      voice_script TEXT,
      created_at TEXT NOT NULL,
      UNIQUE(session_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS actions (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      agent_id TEXT NOT NULL REFERENCES agents(id),
      action_key TEXT NOT NULL,
      title TEXT,
      risk TEXT NOT NULL,
      confirm_required INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL,
      result_json TEXT,
      claimed_at TEXT,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      platform TEXT NOT NULL,
      push_token TEXT,
      locale TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS pushes (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      session_id TEXT NOT NULL REFERENCES sessions(id),
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      voice_script TEXT,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS audit_logs (
      id TEXT PRIMARY KEY,
      user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
      agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
      session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
      action TEXT NOT NULL,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent_id);
    CREATE INDEX IF NOT EXISTS idx_actions_agent_status ON actions(agent_id, status);
    CREATE INDEX IF NOT EXISTS idx_actions_session_status ON actions(session_id, status);
    CREATE INDEX IF NOT EXISTS idx_pushes_user ON pushes(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON audit_logs(user_id, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_audit_logs_session ON audit_logs(session_id, created_at DESC);
  `);
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function addSecondsIso(seconds: number, from = new Date()): string {
  return new Date(from.getTime() + seconds * 1000).toISOString();
}

export function isExpired(iso: string, at = new Date()): boolean {
  return new Date(iso).getTime() <= at.getTime();
}
