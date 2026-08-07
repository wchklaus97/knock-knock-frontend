import { newId } from "./auth.js";
import { isApnsReady, looksLikeApnsToken, sendApnsAlert } from "./apns.js";
import { config } from "./config.js";
import { getDb, nowIso } from "./db.js";

export type PushRecord = {
  push_id: string;
  session_id: string;
  title: string;
  body: string;
  voice_script: string | null;
  created_at: string;
};

export function enqueueDevPush(input: {
  userId: string;
  sessionId: string;
  title: string;
  body: string;
  voiceScript?: string | null;
  payload?: Record<string, unknown>;
}): PushRecord | null {
  const pushId = newId("push");
  const createdAt = nowIso();
  getDb()
    .prepare(
      `INSERT INTO pushes (id, user_id, session_id, title, body, voice_script, payload_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      pushId,
      input.userId,
      input.sessionId,
      input.title,
      input.body,
      input.voiceScript ?? null,
      JSON.stringify(input.payload ?? {}),
      createdAt,
    );

  return {
    push_id: pushId,
    session_id: input.sessionId,
    title: input.title,
    body: input.body,
    voice_script: input.voiceScript ?? null,
    created_at: createdAt,
  };
}

export function listDevPushes(userId?: string, limit = 100): PushRecord[] {
  const safeLimit = Math.min(Math.max(1, Math.floor(limit)), 200);
  const rows = userId
    ? (getDb()
        .prepare(
          `SELECT id, session_id, title, body, voice_script, created_at
           FROM pushes WHERE user_id = ? ORDER BY created_at DESC LIMIT ?`,
        )
        .all(userId, safeLimit) as Array<{
        id: string;
        session_id: string;
        title: string;
        body: string;
        voice_script: string | null;
        created_at: string;
      }>)
    : (getDb()
        .prepare(
          `SELECT id, session_id, title, body, voice_script, created_at
           FROM pushes ORDER BY created_at DESC LIMIT ?`,
        )
        .all(safeLimit) as Array<{
        id: string;
        session_id: string;
        title: string;
        body: string;
        voice_script: string | null;
        created_at: string;
      }>);

  return rows.map((r) => ({
    push_id: r.id,
    session_id: r.session_id,
    title: r.title,
    body: r.body,
    voice_script: r.voice_script,
    created_at: r.created_at,
  }));
}

export type DeviceTokenRow = {
  platform: string;
  push_token: string | null;
};

/**
 * Keep simulator and development placeholder registrations out of APNs.
 * A simulator can expose a 64-character token-shaped value, but it is not a
 * physical device token for this app's sandbox topic.
 */
export function apnsTokensFromDevices(rows: DeviceTokenRow[]): string[] {
  return [
    ...new Set(
      rows
        .filter((row) => row.platform === "ios")
        .map((row) => row.push_token)
        .filter((token): token is string => typeof token === "string" && looksLikeApnsToken(token)),
    ),
  ];
}

function listUserDeviceTokens(userId: string): string[] {
  const rows = getDb()
    .prepare(
      `SELECT platform, push_token FROM devices
       WHERE user_id = ? AND push_token IS NOT NULL AND push_token != ''`,
    )
    .all(userId) as DeviceTokenRow[];
  return apnsTokensFromDevices(rows);
}

/**
 * Notify the user: Dev inbox (unless PUSH_MODE=apns) + real APNs when configured.
 */
export async function notifyUser(input: {
  userId: string;
  sessionId: string;
  title: string;
  body: string;
  voiceScript?: string | null;
  payload?: Record<string, unknown>;
}): Promise<{ inbox: boolean; apnsSent: number; apnsErrors: string[] }> {
  const mode = config.pushMode;
  let inbox = false;
  if (mode === "dev" || mode === "both" || !isApnsReady()) {
    enqueueDevPush(input);
    inbox = true;
  }

  let apnsSent = 0;
  const apnsErrors: string[] = [];
  if ((mode === "apns" || mode === "both") && isApnsReady()) {
    for (const token of listUserDeviceTokens(input.userId)) {
      try {
        await sendApnsAlert(token, {
          title: input.title,
          body: input.body,
          sessionId: input.sessionId,
          voiceScript: input.voiceScript,
        });
        apnsSent += 1;
      } catch (err) {
        apnsErrors.push(err instanceof Error ? err.message : String(err));
      }
    }
  }

  // If apns-only but nothing sent, still keep an inbox row so phone polling works.
  if (!inbox && apnsSent === 0) {
    enqueueDevPush(input);
    inbox = true;
  }

  return { inbox, apnsSent, apnsErrors };
}
