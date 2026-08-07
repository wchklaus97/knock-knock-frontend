import { newId } from "./auth.js";
import { recordAudit } from "./audit.js";
import { addSecondsIso, getDb, isExpired, nowIso } from "./db.js";
import { notifyUser } from "./push.js";
import {
  actionNeedsConfirm,
  getSkill,
  renderSummary,
  resolveSkillActions,
  toVoiceScript,
  type ActionInput,
  type SkillAction,
} from "./skills.js";

export type SessionRow = {
  id: string;
  agent_id: string;
  user_id: string;
  skill_id: string;
  state: string;
  progress_status: string | null;
  progress_message: string | null;
  progress_percent: number | null;
  title: string | null;
  chat_id: string | null;
  summary_text: string | null;
  voice_script: string | null;
  facts_json: string;
  available_actions_json: string | null;
  idempotency_key: string | null;
  expires_at: string;
  created_at: string;
  updated_at: string;
};

export type ActionRow = {
  id: string;
  session_id: string;
  agent_id: string;
  action_key: string;
  title: string | null;
  risk: string;
  confirm_required: number;
  status: string;
  result_json: string | null;
  claimed_at: string | null;
  expires_at: string;
  created_at: string;
  updated_at: string;
};

const waitingSessionStates = new Set(["needs_user", "awaiting_confirm"]);
const activePhoneActionStatuses = ["offered", "pending_confirm", "awaiting_confirm"] as const;

export function sessionToApi(row: SessionRow) {
  expireSessionIfNeeded(row);
  const fresh = getSessionRow(row.id) ?? row;
  return {
    session_id: fresh.id,
    agent_id: fresh.agent_id,
    skill_id: fresh.skill_id,
    state: fresh.state,
    progress_status: fresh.progress_status,
    progress_message: fresh.progress_message,
    progress_percent: fresh.progress_percent,
    chat_id: fresh.chat_id,
    title: fresh.title,
    summary_text: fresh.summary_text,
    voice_script: fresh.voice_script,
    available_actions: fresh.available_actions_json
      ? (JSON.parse(fresh.available_actions_json) as string[])
      : [],
    facts: JSON.parse(fresh.facts_json || "{}") as Record<string, unknown>,
    expires_at: fresh.expires_at,
    created_at: fresh.created_at,
    updated_at: fresh.updated_at,
  };
}

export function actionToApi(row: ActionRow) {
  expireActionIfNeeded(row);
  const fresh = getActionRow(row.id) ?? row;
  const result = fresh.result_json ? JSON.parse(fresh.result_json) : null;
  return {
    action_id: fresh.id,
    session_id: fresh.session_id,
    action_key: fresh.action_key,
    title: fresh.title,
    risk: fresh.risk,
    confirm_required: Boolean(fresh.confirm_required),
    status: fresh.status,
    expires_at: fresh.expires_at,
    claimed_at: fresh.claimed_at,
    result,
    cancelled_by_user: Boolean(result && typeof result === "object" && result.cancelled === true),
  };
}

function activeActionsForSession(sessionId: string): ActionRow[] {
  return getDb()
    .prepare(
      `SELECT * FROM actions
       WHERE session_id = ? AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')
       ORDER BY created_at ASC`,
    )
    .all(sessionId) as ActionRow[];
}

/**
 * Keep the phone-facing session metadata aligned with executable action rows.
 * This repairs sessions created by an older build, action expiry, or a
 * partially completed migration instead of rendering dead buttons on phone.
 */
function reconcileWaitingSession(row: SessionRow): SessionRow {
  expireSessionIfNeeded(row);
  const current = getSessionRow(row.id) ?? row;
  if (!waitingSessionStates.has(current.state)) return current;

  for (const action of activeActionsForSession(current.id)) expireActionIfNeeded(action);
  const activeActions = activeActionsForSession(current.id).filter((action) => {
    return activePhoneActionStatuses.includes(action.status as (typeof activePhoneActionStatuses)[number]);
  });
  const activeActionKeys = [...new Set(activeActions.map((action) => action.action_key))];
  const storedActionKeys = current.available_actions_json
    ? (JSON.parse(current.available_actions_json) as string[])
    : [];

  if (activeActionKeys.length === 0) {
    const updatedAt = nowIso();
    getDb()
      .prepare(
        `UPDATE sessions SET state = 'running', available_actions_json = NULL,
           progress_message = ?, updated_at = ?
         WHERE id = ? AND state IN ('needs_user', 'awaiting_confirm')
           AND NOT EXISTS (
             SELECT 1 FROM actions
             WHERE session_id = sessions.id
               AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')
           )`,
      )
      .run(
        "No actionable phone decision remains; the agent must emit a new decision.",
        updatedAt,
        current.id,
      );
    return getSessionRow(current.id) ?? current;
  }

  if (JSON.stringify(activeActionKeys) !== JSON.stringify(storedActionKeys)) {
    getDb()
      .prepare("UPDATE sessions SET available_actions_json = ?, updated_at = ? WHERE id = ?")
      .run(JSON.stringify(activeActionKeys), nowIso(), current.id);
    return getSessionRow(current.id) ?? current;
  }

  return current;
}

function actionWasCancelledByUser(row: ActionRow): boolean {
  if (!row.result_json) return false;
  try {
    const result = JSON.parse(row.result_json) as { cancelled?: unknown };
    return result.cancelled === true;
  } catch {
    return false;
  }
}

export function getSessionRow(id: string): SessionRow | null {
  return (
    (getDb().prepare("SELECT * FROM sessions WHERE id = ?").get(id) as SessionRow | undefined) ??
    null
  );
}

export function getActionRow(id: string): ActionRow | null {
  return (
    (getDb().prepare("SELECT * FROM actions WHERE id = ?").get(id) as ActionRow | undefined) ?? null
  );
}

function expireSessionIfNeeded(row: SessionRow): void {
  if (["expired", "completed", "failed"].includes(row.state)) return;
  if (!isExpired(row.expires_at)) return;
  getDb()
    .prepare("UPDATE sessions SET state = 'expired', updated_at = ? WHERE id = ?")
    .run(nowIso(), row.id);
}

function expireActionIfNeeded(row: ActionRow): void {
  if (["completed", "done", "failed", "expired", "cancelled"].includes(row.status)) return;
  if (!isExpired(row.expires_at)) return;
  getDb()
    .prepare("UPDATE actions SET status = 'expired', updated_at = ? WHERE id = ?")
    .run(nowIso(), row.id);
}

export function createOrResumeSession(input: {
  agentId: string;
  userId: string;
  skillId: string;
  sessionId?: string;
  idempotencyKey?: string;
  title?: string;
  chatId?: string;
  facts?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
}): SessionRow {
  const skill = getSkill(input.skillId);
  if (!skill) {
    throw Object.assign(new Error("Unknown skill_id"), { status: 404 });
  }

  const database = getDb();

  if (input.sessionId) {
    const existing = getSessionRow(input.sessionId);
    if (!existing || existing.agent_id !== input.agentId) {
      throw Object.assign(new Error("Session not found"), { status: 404 });
    }
    expireSessionIfNeeded(existing);
    const fresh = getSessionRow(existing.id)!;
    if (fresh.state === "expired") {
      throw Object.assign(new Error("Session expired"), { status: 410 });
    }
    return fresh;
  }

  if (input.idempotencyKey) {
    const existing = database
      .prepare("SELECT * FROM sessions WHERE agent_id = ? AND idempotency_key = ?")
      .get(input.agentId, input.idempotencyKey) as SessionRow | undefined;
    if (existing) {
      expireSessionIfNeeded(existing);
      return getSessionRow(existing.id)!;
    }
  }

  const id = newId("ses");
  const createdAt = nowIso();
  const expiresAt = addSecondsIso(skill.ttl.default_sec);
  const facts = input.facts ?? {};
  database
    .prepare(
      `INSERT INTO sessions (
        id, agent_id, user_id, skill_id, state, progress_status, progress_message,
        title, chat_id, summary_text, voice_script, facts_json, available_actions_json,
        idempotency_key, expires_at, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 'open', NULL, NULL, ?, ?, NULL, NULL, ?, NULL, ?, ?, ?, ?)
       ON CONFLICT(agent_id, idempotency_key) DO NOTHING`,
    )
    .run(
      id,
      input.agentId,
      input.userId,
      input.skillId,
      input.title ?? null,
      input.chatId ?? (input.metadata?.chat_id as string | undefined) ?? null,
      JSON.stringify(facts),
      input.idempotencyKey ?? null,
      expiresAt,
      createdAt,
      createdAt,
    );
  if (input.idempotencyKey) {
    const existing = database
      .prepare("SELECT * FROM sessions WHERE agent_id = ? AND idempotency_key = ?")
      .get(input.agentId, input.idempotencyKey) as SessionRow | undefined;
    if (existing && existing.id !== id) {
      expireSessionIfNeeded(existing);
      return getSessionRow(existing.id)!;
    }
  }
  const created = getSessionRow(id)!;
  recordAudit({
    action: "session.create",
    userId: input.userId,
    agentId: input.agentId,
    sessionId: created.id,
    metadata: { skill_id: input.skillId, title: input.title ?? null },
  });
  return created;
}

export function updateProgress(
  session: SessionRow,
  input: {
    status: string;
    message?: string;
    percent?: number;
    facts?: Record<string, unknown>;
  },
): SessionRow {
  expireSessionIfNeeded(session);
  const current = getSessionRow(session.id)!;
  if (["expired", "closed", "completed", "failed"].includes(current.state)) {
    throw Object.assign(new Error(`Session is ${current.state}`), { status: 409 });
  }

  const facts = {
    ...(JSON.parse(current.facts_json || "{}") as Record<string, unknown>),
    ...(input.facts ?? {}),
  };
  const protectedStates = new Set(["needs_user", "awaiting_confirm", "queued", "claimed"]);
  const nextState = protectedStates.has(current.state) ? current.state : "running";
  const updatedAt = nowIso();
  getDb()
    .prepare(
      `UPDATE sessions SET
        state = ?,
        progress_status = ?,
        progress_message = ?,
        progress_percent = ?,
        facts_json = ?,
        updated_at = ?
       WHERE id = ?`,
    )
    .run(
      nextState,
      input.status,
      input.message ?? current.progress_message,
      input.percent ?? current.progress_percent,
      JSON.stringify(facts),
      updatedAt,
      current.id,
    );
  // NEVER push on progress
  return getSessionRow(current.id)!;
}

function shouldPushEvent(status: string, actions: SkillAction[], forcePush?: boolean): boolean {
  if (status === "needs_user") return true;
  if (forcePush) return true;
  if ((status === "succeeded" || status === "failed") && actions.length > 0) return true;
  return false;
}

export function reportEvent(
  session: SessionRow,
  input: {
    status: string;
    summary?: string;
    facts?: Record<string, unknown>;
    actions?: ActionInput[];
    idempotencyKey?: string;
    forcePush?: boolean;
  },
): {
  pushed: boolean;
  summary_text: string;
  voice_script: string;
  session: ReturnType<typeof sessionToApi>;
  event_id: string;
} {
  expireSessionIfNeeded(session);
  const current = getSessionRow(session.id)!;
  if (current.state === "expired") {
    throw Object.assign(new Error("Session expired"), { status: 410 });
  }

  const skill = getSkill(current.skill_id);
  if (!skill) {
    throw Object.assign(new Error("Skill missing"), { status: 500 });
  }

  const database = getDb();

  if (input.idempotencyKey) {
    const prev = database
      .prepare("SELECT * FROM events WHERE session_id = ? AND idempotency_key = ?")
      .get(current.id, input.idempotencyKey) as
      | {
          id: string;
          pushed: number;
          summary_text: string | null;
          voice_script: string | null;
        }
      | undefined;
    if (prev) {
      return {
        pushed: Boolean(prev.pushed),
        summary_text: prev.summary_text ?? "",
        voice_script: prev.voice_script ?? "",
        session: sessionToApi(getSessionRow(current.id)!),
        event_id: prev.id,
      };
    }
  }

  const resolvedActions = resolveSkillActions(skill, input.actions);
  if (input.status === "needs_user" && resolvedActions.length === 0) {
    throw Object.assign(new Error("needs_user requires actions"), { status: 400 });
  }

  const facts = {
    ...(JSON.parse(current.facts_json || "{}") as Record<string, unknown>),
    ...(input.facts ?? {}),
  };
  const summaryText = input.summary?.trim() || renderSummary(skill.template, facts);
  const voiceScript = toVoiceScript(summaryText);
  const push = shouldPushEvent(input.status, resolvedActions, input.forcePush);

  let nextState = current.state;
  if (input.status === "needs_user") nextState = "needs_user";
  else if (input.status === "succeeded") nextState = resolvedActions.length ? "needs_user" : "closed";
  else if (input.status === "failed") nextState = resolvedActions.length ? "needs_user" : "closed";
  else if (input.status === "info") nextState = current.state === "needs_user" ? current.state : "running";

  const updatedAt = nowIso();
  const eventId = newId("evt");
  const actionKeys = resolvedActions.map((a) => a.id);

  const tx = database.transaction(() => {
    const eventInsert = database
      .prepare(
        `INSERT INTO events (id, session_id, status, idempotency_key, payload_json, pushed, summary_text, voice_script, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(session_id, idempotency_key) DO NOTHING`,
      )
      .run(
        eventId,
        current.id,
        input.status,
        input.idempotencyKey ?? null,
        JSON.stringify({
          facts,
          actions: resolvedActions,
          force_push: Boolean(input.forcePush),
        }),
        push ? 1 : 0,
        summaryText,
        voiceScript,
        updatedAt,
      );

    if (eventInsert.changes === 0 && input.idempotencyKey) {
      const previous = database
        .prepare("SELECT id, pushed, summary_text, voice_script FROM events WHERE session_id = ? AND idempotency_key = ?")
        .get(current.id, input.idempotencyKey) as
        | { id: string; pushed: number; summary_text: string | null; voice_script: string | null }
        | undefined;
      if (!previous) {
        throw Object.assign(new Error("Event idempotency conflict"), { status: 409 });
      }
      return {
        duplicate: true as const,
        pushed: Boolean(previous.pushed),
        summaryText: previous.summary_text ?? "",
        voiceScript: previous.voice_script ?? "",
        eventId: previous.id,
      };
    }

    if (resolvedActions.length > 0) {
      database
        .prepare(
          `UPDATE actions SET status = 'cancelled', updated_at = ?
           WHERE session_id = ? AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')`,
        )
        .run(updatedAt, current.id);

      for (const action of resolvedActions) {
        const ttl =
          action.risk === "destructive" || actionNeedsConfirm(action)
            ? skill.ttl.destructive_sec
            : skill.ttl.default_sec;
        database
          .prepare(
            `INSERT INTO actions (
              id, session_id, agent_id, action_key, title, risk, confirm_required,
              status, result_json, claimed_at, expires_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'offered', NULL, NULL, ?, ?, ?)`,
          )
          .run(
            newId("act"),
            current.id,
            current.agent_id,
            action.id,
            action.title,
            action.risk,
            actionNeedsConfirm(action) ? 1 : 0,
            addSecondsIso(ttl),
            updatedAt,
            updatedAt,
          );
      }
    }

    database
      .prepare(
        `UPDATE sessions SET
          state = ?,
          summary_text = ?,
          voice_script = ?,
          facts_json = ?,
          available_actions_json = ?,
          updated_at = ?
         WHERE id = ?`,
      )
      .run(
        nextState,
        summaryText,
        voiceScript,
        JSON.stringify(facts),
        actionKeys.length ? JSON.stringify(actionKeys) : null,
        updatedAt,
        current.id,
      );

    return { duplicate: false as const };
  });

  const transactionResult = tx();
  if (transactionResult.duplicate) {
    return {
      pushed: transactionResult.pushed,
      summary_text: transactionResult.summaryText,
      voice_script: transactionResult.voiceScript,
      session: sessionToApi(getSessionRow(current.id)!),
      event_id: transactionResult.eventId,
    };
  }

  recordAudit({
    action: `session.event.${input.status}`,
    userId: current.user_id,
    agentId: current.agent_id,
    sessionId: current.id,
    metadata: { event_id: eventId, actions: actionKeys, pushed: push },
  });

  if (push) {
    void notifyUser({
      userId: current.user_id,
      sessionId: current.id,
      title: current.title || skill.skill_id,
      body: summaryText,
      voiceScript,
      payload: {
        event_id: eventId,
        status: input.status,
        actions: actionKeys,
      },
    })
      .then((r) => {
        console.log(
          `[push] session=${current.id} inbox=${r.inbox} apnsSent=${r.apnsSent}` +
            (r.apnsErrors.length ? ` errors=${r.apnsErrors.join(" | ")}` : ""),
        );
      })
      .catch((err) => {
        console.error("[push] notifyUser failed", err);
      });
  }

  return {
    pushed: push,
    summary_text: summaryText,
    voice_script: voiceScript,
    session: sessionToApi(getSessionRow(current.id)!),
    event_id: eventId,
  };
}

export function listQueuedActions(opts: {
  agentId: string;
  sessionId?: string;
}): ActionRow[] {
  const rows = opts.sessionId
    ? (getDb()
        .prepare(
          `SELECT * FROM actions
           WHERE agent_id = ? AND session_id = ? AND status = 'queued'
           ORDER BY created_at ASC`,
        )
        .all(opts.agentId, opts.sessionId) as ActionRow[])
    : (getDb()
        .prepare(
          `SELECT * FROM actions
           WHERE agent_id = ? AND status = 'queued'
           ORDER BY created_at ASC`,
        )
        .all(opts.agentId) as ActionRow[]);

  for (const row of rows) expireActionIfNeeded(row);
  return rows.map((r) => getActionRow(r.id)!).filter((r) => r.status === "queued");
}

export function claimActions(actions: ActionRow[]): ActionRow[] {
  const database = getDb();
  const updatedAt = nowIso();
  const claimed: ActionRow[] = [];
  const tx = database.transaction(() => {
    const claimedSessionIds = new Set<string>();
    for (const action of actions) {
      const result = database
        .prepare(
          `UPDATE actions SET status = 'claimed', claimed_at = ?, updated_at = ?
           WHERE id = ? AND status = 'queued'`,
        )
        .run(updatedAt, updatedAt, action.id);
      if (result.changes > 0) {
        claimed.push(getActionRow(action.id)!);
        claimedSessionIds.add(action.session_id);
      }
    }
    for (const sessionId of claimedSessionIds) {
      database
        .prepare(
          `UPDATE sessions SET state = 'claimed', updated_at = ?
           WHERE id = ? AND state = 'queued'`,
        )
        .run(updatedAt, sessionId);
    }
  });
  tx();
  return claimed;
}

export async function waitForPendingActions(opts: {
  agentId: string;
  sessionId?: string;
  claim: boolean;
  waitMs: number;
}): Promise<ActionRow[]> {
  const deadline = Date.now() + Math.max(0, opts.waitMs);
  for (;;) {
    let actions = listQueuedActions({ agentId: opts.agentId, sessionId: opts.sessionId });
    if (actions.length > 0) {
      if (opts.claim) actions = claimActions(actions);
      return actions;
    }
    if (Date.now() >= deadline) return [];
    await new Promise((r) => setTimeout(r, Math.min(200, Math.max(0, deadline - Date.now()))));
  }
}

export function phoneReply(input: {
  userId: string;
  sessionId: string;
  actionKey: string;
  utterance?: string | null;
}): {
  session: ReturnType<typeof sessionToApi>;
  action: ReturnType<typeof actionToApi>;
  needs_confirm: boolean;
} {
  const session = getSessionRow(input.sessionId);
  if (!session || session.user_id !== input.userId) {
    throw Object.assign(new Error("Session not found"), { status: 404 });
  }
  expireSessionIfNeeded(session);
  const current = getSessionRow(session.id)!;
  if (current.state === "expired") {
    throw Object.assign(new Error("Session expired"), { status: 410 });
  }

  const action = getDb()
    .prepare(
      `SELECT * FROM actions
       WHERE session_id = ? AND action_key = ? AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')
       ORDER BY created_at DESC LIMIT 1`,
    )
    .get(current.id, input.actionKey) as ActionRow | undefined;

  if (!action) {
    throw Object.assign(new Error("Action not available"), { status: 404 });
  }
  expireActionIfNeeded(action);
  const fresh = getActionRow(action.id)!;
  if (fresh.status === "expired") {
    throw Object.assign(new Error("Action expired"), { status: 410 });
  }

  const needsConfirm = Boolean(fresh.confirm_required) || fresh.risk === "destructive";
  // A retry after a lost phone response should be idempotent. Return the
  // existing confirmation state instead of creating a second transition.
  if (fresh.status === "pending_confirm" || fresh.status === "awaiting_confirm") {
    return {
      session: sessionToApi(getSessionRow(current.id)!),
      action: actionToApi(fresh),
      needs_confirm: true,
    };
  }
  if (fresh.status !== "offered") {
    throw Object.assign(new Error(`Action status is ${fresh.status}`), { status: 409 });
  }

  const updatedAt = nowIso();
  const nextActionStatus = needsConfirm ? "pending_confirm" : "queued";
  const nextSessionState = needsConfirm ? "awaiting_confirm" : "queued";

  const database = getDb();
  const tx = database.transaction(() => {
    const actionUpdate = database
      .prepare(
        `UPDATE actions SET status = ?, updated_at = ?
         WHERE id = ? AND status = 'offered'`,
      )
      .run(nextActionStatus, updatedAt, fresh.id);
    if (actionUpdate.changes === 0) {
      throw Object.assign(new Error("Action is no longer available"), { status: 409 });
    }

    if (!needsConfirm) {
      database
        .prepare(
          `UPDATE actions SET status = 'cancelled', updated_at = ?
           WHERE session_id = ? AND id <> ? AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')`,
        )
        .run(updatedAt, current.id, fresh.id);
    }

    const sessionUpdate = database
      .prepare(
        `UPDATE sessions SET state = ?,
           available_actions_json = CASE WHEN ? = 1 THEN available_actions_json ELSE NULL END,
           updated_at = ?
         WHERE id = ? AND state IN ('needs_user', 'awaiting_confirm')`,
      )
      .run(nextSessionState, needsConfirm ? 1 : 0, updatedAt, current.id);
    if (sessionUpdate.changes === 0) {
      throw Object.assign(new Error("Session is no longer waiting for a reply"), { status: 409 });
    }
  });
  tx();

  recordAudit({
    action: "phone.reply",
    userId: input.userId,
    agentId: current.agent_id,
    sessionId: current.id,
    metadata: { action_id: fresh.id, action_key: fresh.action_key, needs_confirm: needsConfirm },
  });

  return {
    session: sessionToApi(getSessionRow(current.id)!),
    action: actionToApi(getActionRow(fresh.id)!),
    needs_confirm: needsConfirm,
  };
}

export function phoneConfirm(input: {
  userId: string;
  sessionId: string;
  actionId: string;
  confirm: boolean;
}): {
  session: ReturnType<typeof sessionToApi>;
  action: ReturnType<typeof actionToApi>;
  needs_confirm: boolean;
} {
  const session = getSessionRow(input.sessionId);
  if (!session || session.user_id !== input.userId) {
    throw Object.assign(new Error("Session not found"), { status: 404 });
  }
  expireSessionIfNeeded(session);
  const currentSession = getSessionRow(session.id)!;
  if (currentSession.state === "expired") {
    throw Object.assign(new Error("Session expired"), { status: 410 });
  }

  const action = getActionRow(input.actionId);
  if (!action || action.session_id !== session.id) {
    throw Object.assign(new Error("Action not found"), { status: 404 });
  }
  expireActionIfNeeded(action);
  const fresh = getActionRow(action.id)!;
  if (fresh.status === "expired") {
    throw Object.assign(new Error("Action expired"), { status: 410 });
  }
  if (!input.confirm && ["queued", "cancelled"].includes(fresh.status) && actionWasCancelledByUser(fresh)) {
    return {
      session: sessionToApi(getSessionRow(session.id)!),
      action: actionToApi(fresh),
      needs_confirm: false,
    };
  }
  if (input.confirm && ["queued", "cancelled"].includes(fresh.status) && actionWasCancelledByUser(fresh)) {
    throw Object.assign(new Error("Action was cancelled on the phone"), { status: 409 });
  }
  if (input.confirm && fresh.status === "queued") {
    return {
      session: sessionToApi(getSessionRow(session.id)!),
      action: actionToApi(fresh),
      needs_confirm: false,
    };
  }
  if (!input.confirm && fresh.status === "cancelled") {
    return {
      session: sessionToApi(getSessionRow(session.id)!),
      action: actionToApi(fresh),
      needs_confirm: false,
    };
  }
  if (fresh.status !== "pending_confirm" && fresh.status !== "awaiting_confirm") {
    throw Object.assign(new Error("Action is not awaiting confirm"), { status: 409 });
  }

  const updatedAt = nowIso();
  const availableActionKeys = currentSession.available_actions_json
    ? (JSON.parse(currentSession.available_actions_json) as string[])
    : [];
  const remainingActionKeys = availableActionKeys.filter((key) => key !== fresh.action_key);
  const queueCancellation = !input.confirm && remainingActionKeys.length === 0;
  const nextActionStatus = input.confirm
    ? "queued"
    : queueCancellation
      ? "queued"
      : "cancelled";
  const cancellationResult = JSON.stringify({
    ok: false,
    cancelled: true,
    message: "User cancelled this action on the phone",
    output: null,
  });
  const database = getDb();
  const tx = database.transaction(() => {
    const actionUpdate = database
      .prepare(
        `UPDATE actions SET status = ?, result_json = CASE WHEN ? = 1 THEN ? ELSE result_json END, updated_at = ?
         WHERE id = ? AND status IN ('pending_confirm', 'awaiting_confirm')`,
      )
      .run(nextActionStatus, input.confirm ? 0 : 1, cancellationResult, updatedAt, fresh.id);
    if (actionUpdate.changes === 0) {
      throw Object.assign(new Error("Action is no longer awaiting confirm"), { status: 409 });
    }
    if (input.confirm) {
      database
        .prepare(
          `UPDATE actions SET status = 'cancelled', updated_at = ?
           WHERE session_id = ? AND id <> ? AND status IN ('offered', 'pending_confirm', 'awaiting_confirm')`,
        )
        .run(updatedAt, currentSession.id, fresh.id);
    }

    const sessionUpdate = input.confirm
        ? database
            .prepare(
            `UPDATE sessions SET state = 'queued', available_actions_json = NULL, updated_at = ?
             WHERE id = ? AND state = 'awaiting_confirm'`,
          )
          .run(updatedAt, currentSession.id)
      : queueCancellation
        ? database
            .prepare(
              `UPDATE sessions SET state = 'queued', available_actions_json = NULL,
                 progress_message = ?, updated_at = ?
               WHERE id = ? AND state = 'awaiting_confirm'`,
            )
            .run("User cancelled this action on the phone.", updatedAt, currentSession.id)
        : database
          .prepare(
            `UPDATE sessions SET state = 'needs_user', available_actions_json = ?,
               progress_message = ?, updated_at = ?
             WHERE id = ? AND state = 'awaiting_confirm'`,
          )
          .run(
            remainingActionKeys.length ? JSON.stringify(remainingActionKeys) : null,
            "That action was cancelled. Choose another option or wait for the agent.",
            updatedAt,
            currentSession.id,
          );
    if (sessionUpdate.changes === 0) {
      throw Object.assign(new Error("Session is no longer awaiting confirm"), { status: 409 });
    }
  });
  tx();

  recordAudit({
    action: input.confirm ? "phone.confirm" : "phone.cancel",
    userId: input.userId,
    agentId: currentSession.agent_id,
    sessionId: currentSession.id,
    metadata: { action_id: fresh.id, action_key: fresh.action_key },
  });

  return {
    session: sessionToApi(getSessionRow(session.id)!),
    action: actionToApi(getActionRow(fresh.id)!),
    needs_confirm: false,
  };
}

export function submitActionResult(input: {
  agentId: string;
  actionId: string;
  ok: boolean;
  message?: string;
  output?: Record<string, unknown>;
}): ReturnType<typeof actionToApi> {
  const action = getActionRow(input.actionId);
  if (!action || action.agent_id !== input.agentId) {
    throw Object.assign(new Error("Action not found"), { status: 404 });
  }
  expireActionIfNeeded(action);
  const fresh = getActionRow(action.id)!;
  if (fresh.status === "expired") {
    throw Object.assign(new Error("Action expired"), { status: 410 });
  }
  // A network retry after a successful result should be safe. Returning the
  // stored action keeps the agent loop idempotent without executing twice.
  if (fresh.status === "done" || fresh.status === "failed") {
    return actionToApi(fresh);
  }
  if (fresh.status !== "claimed" && fresh.status !== "queued") {
    throw Object.assign(new Error(`Action status is ${fresh.status}`), { status: 409 });
  }

  const updatedAt = nowIso();
  const status = input.ok ? "done" : "failed";
  const previousResult = fresh.result_json ? JSON.parse(fresh.result_json) as { cancelled?: boolean; message?: string } : null;
  if (previousResult?.cancelled && input.ok) {
    throw Object.assign(new Error("Action was cancelled by the user; do not execute it"), { status: 409 });
  }
  const resultJson = JSON.stringify({
    ok: input.ok,
    cancelled: previousResult?.cancelled === true ? true : undefined,
    message: input.message ?? previousResult?.message ?? null,
    output: input.output ?? null,
  });
  const database = getDb();
  const tx = database.transaction(() => {
    const current = getActionRow(fresh.id)!;
    if (current.status === "done" || current.status === "failed") return current;
    if (current.status !== "claimed" && current.status !== "queued") {
      throw Object.assign(new Error(`Action status is ${current.status}`), { status: 409 });
    }

    const actionUpdate = database
      .prepare(
        `UPDATE actions SET status = ?, result_json = ?, updated_at = ?
         WHERE id = ? AND status IN ('claimed', 'queued')`,
      )
      .run(status, resultJson, updatedAt, fresh.id);
    if (actionUpdate.changes === 0) {
      const after = getActionRow(fresh.id)!;
      if (after.status === "done" || after.status === "failed") return after;
      throw Object.assign(new Error(`Action status is ${after.status}`), { status: 409 });
    }

    database
      .prepare(`UPDATE sessions SET state = ?, available_actions_json = NULL, updated_at = ? WHERE id = ?`)
      .run(input.ok ? "running" : "closed", updatedAt, fresh.session_id);

    return getActionRow(fresh.id)!;
  });

  const result = tx();
  recordAudit({
    action: `agent.action_result.${status}`,
    agentId: input.agentId,
    sessionId: fresh.session_id,
    metadata: { action_id: fresh.id, ok: input.ok },
  });
  return actionToApi(result);
}

export function listPhoneSessions(userId: string, limit = 100) {
  const safeLimit = Math.min(Math.max(1, Math.floor(limit)), 200);
  const rows = getDb()
    .prepare(`SELECT * FROM sessions WHERE user_id = ? ORDER BY updated_at DESC LIMIT ?`)
    .all(userId, safeLimit) as SessionRow[];
  return rows.map(reconcileWaitingSession).map(sessionToApi);
}
