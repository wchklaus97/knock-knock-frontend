import crypto from "node:crypto";
import { sanitizeAgentResponseData } from "./redaction.js";
import { currentListenerGeneration } from "./thread-binding.js";

export type AskClaimPhase =
  | "unclaimed"
  | "active"
  | "recoverable"
  | "legacy-drain"
  | "settled";

type AskClaimCredential = Readonly<{
  token: string;
  claimGeneration: number;
  listenerGeneration: number;
  deadline: string;
}>;

type AskWriteKind = "answer" | "progress";

type DirectAskAnswerRequestBinding = Readonly<{
  identityDigest: string;
  payloadDigest: string;
  idempotencyKeyDigest: string;
}>;

type DirectAskAnswerReservation = DirectAskAnswerRequestBinding &
  Readonly<{
    state: "in-flight" | "retryable";
    attempt: 1 | 2;
  }>;

type DirectAskAnswerTerminal = DirectAskAnswerRequestBinding &
  Readonly<{
    outcome: "delivered" | "failed-closed";
  }>;

type AskWriteReservation = Readonly<{
  ownerToken: string;
  credential: AskClaimCredential;
  kind: AskWriteKind;
  directAnswer?: DirectAskAnswerReservation;
}>;

type StoredAskClaim = {
  askId: string;
  sessionId?: string;
  clientTurnId?: string;
  credential?: AskClaimCredential;
  deferredCredential?: AskClaimCredential;
  phase: AskClaimPhase;
  writeReservation?: AskWriteReservation;
  answerTerminal?: DirectAskAnswerTerminal;
  updatedAtMs: number;
  lastError?: string;
};

export type AskClaimStatus = Readonly<{
  askId: string;
  sessionId?: string;
  clientTurnId?: string;
  claimGeneration?: number;
  listenerGeneration?: number;
  claimDeadline?: string;
  phase: AskClaimPhase;
  answerInFlight: boolean;
  progressInFlight: boolean;
  lastError?: string;
}>;

export type PreparedPhoneAskRequest = {
  askId?: string;
  reservationToken?: string;
  body: Record<string, unknown>;
};

export const MAX_LOCAL_ASK_CLAIMS = 256;
export const SETTLED_ASK_RETENTION_MS = 60_000;
export const INACTIVE_ASK_RETENTION_MS = 5 * 60_000;

export class PhoneAskClaimError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(`${code}: ${message}`);
    this.name = "PhoneAskClaimError";
  }
}

const claimsByAskId = new Map<string, StoredAskClaim>();
const askIdsBySession = new Map<string, Set<string>>();

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : undefined;
}

function deadlineMilliseconds(deadline: string | undefined): number | undefined {
  if (!deadline) return undefined;
  const milliseconds = Date.parse(deadline);
  return Number.isFinite(milliseconds) ? milliseconds : undefined;
}

function deadlineExpired(deadline: string | undefined, nowMs = Date.now()): boolean {
  const milliseconds = deadlineMilliseconds(deadline);
  return milliseconds === undefined || milliseconds <= nowMs;
}

function publicStatus(claim: StoredAskClaim): AskClaimStatus {
  const reservation = claim.writeReservation;
  return Object.freeze({
    askId: claim.askId,
    sessionId: claim.sessionId,
    clientTurnId: claim.clientTurnId,
    claimGeneration: claim.credential?.claimGeneration,
    listenerGeneration: claim.credential?.listenerGeneration,
    claimDeadline: claim.credential?.deadline,
    phase: claim.phase,
    answerInFlight:
      reservation?.kind === "answer" &&
      reservation.directAnswer?.state !== "retryable",
    progressInFlight: reservation?.kind === "progress",
    lastError: claim.lastError,
  });
}

function directAnswerRetryPending(claim: StoredAskClaim): boolean {
  return claim.writeReservation?.directAnswer?.state === "retryable";
}

function askWriteInFlight(claim: StoredAskClaim): boolean {
  return Boolean(claim.writeReservation) && !directAnswerRetryPending(claim);
}

function terminalizeDirectAnswer(
  claim: StoredAskClaim,
  binding: DirectAskAnswerRequestBinding,
  outcome: DirectAskAnswerTerminal["outcome"],
  lastError: string | undefined,
  nowMs = Date.now(),
): void {
  claim.phase = "settled";
  claim.credential = undefined;
  claim.deferredCredential = undefined;
  claim.writeReservation = undefined;
  claim.answerTerminal = Object.freeze({
    identityDigest: binding.identityDigest,
    payloadDigest: binding.payloadDigest,
    idempotencyKeyDigest: binding.idempotencyKeyDigest,
    outcome,
  });
  claim.updatedAtMs = nowMs;
  claim.lastError = lastError;
}

function deleteClaim(askId: string): void {
  const claim = claimsByAskId.get(askId);
  if (!claim) return;
  claimsByAskId.delete(askId);
  if (!claim.sessionId) return;
  const sessionIds = askIdsBySession.get(claim.sessionId);
  sessionIds?.delete(askId);
  if (sessionIds?.size === 0) askIdsBySession.delete(claim.sessionId);
}

export function pruneAskClaimState(nowMs = Date.now()): void {
  for (const claim of claimsByAskId.values()) {
    const credentialDeadline = deadlineMilliseconds(claim.credential?.deadline);
    if (
      claim.credential &&
      !askWriteInFlight(claim) &&
      credentialDeadline !== undefined &&
      credentialDeadline <= nowMs
    ) {
      const retryBinding = claim.writeReservation?.directAnswer;
      if (retryBinding?.state === "retryable") {
        terminalizeDirectAnswer(
          claim,
          retryBinding,
          "failed-closed",
          "phone_ask_answer_authority_expired",
          nowMs,
        );
      } else {
        claim.credential = undefined;
        claim.deferredCredential = undefined;
        claim.writeReservation = undefined;
        if (claim.phase !== "settled" && claim.phase !== "legacy-drain") {
          claim.phase = "recoverable";
          claim.lastError = "phone_ask_claim_expired";
        }
      }
    }

    const retentionMs =
      claim.answerTerminal
        ? INACTIVE_ASK_RETENTION_MS
        : claim.phase === "settled"
          ? SETTLED_ASK_RETENTION_MS
          : INACTIVE_ASK_RETENTION_MS;
    const expiredCredentialAge =
      credentialDeadline === undefined ? 0 : nowMs - credentialDeadline;
    if (
      (!askWriteInFlight(claim) && nowMs - claim.updatedAtMs > retentionMs) ||
      (!askWriteInFlight(claim) &&
        credentialDeadline !== undefined &&
        expiredCredentialAge > INACTIVE_ASK_RETENTION_MS)
    ) {
      deleteClaim(claim.askId);
    }
  }

  if (claimsByAskId.size <= MAX_LOCAL_ASK_CLAIMS) return;
  const oldest = [...claimsByAskId.values()]
    .filter((claim) => !askWriteInFlight(claim))
    .sort((left, right) => left.updatedAtMs - right.updatedAtMs);
  for (const claim of oldest) {
    if (claimsByAskId.size <= MAX_LOCAL_ASK_CLAIMS) break;
    deleteClaim(claim.askId);
  }
}

function saveClaim(claim: StoredAskClaim): void {
  const previous = claimsByAskId.get(claim.askId);
  if (previous?.sessionId && previous.sessionId !== claim.sessionId) {
    const previousIds = askIdsBySession.get(previous.sessionId);
    previousIds?.delete(claim.askId);
    if (previousIds?.size === 0) askIdsBySession.delete(previous.sessionId);
  }
  claimsByAskId.set(claim.askId, claim);
  if (claim.sessionId) {
    const ids = askIdsBySession.get(claim.sessionId) ?? new Set<string>();
    ids.add(claim.askId);
    askIdsBySession.set(claim.sessionId, ids);
  }
  pruneAskClaimState(claim.updatedAtMs);
}

function credentialFrom(value: Record<string, unknown>): AskClaimCredential | undefined {
  const token = stringValue(value.claim_token);
  const claimGeneration =
    positiveInteger(value.claim_generation) ?? positiveInteger(value.generation);
  const listenerGeneration =
    positiveInteger(value.listener_generation) ??
    positiveInteger(value.resolved_generation) ??
    claimGeneration;
  const deadline = stringValue(value.claim_deadline);
  if (!token || !claimGeneration || !listenerGeneration || !deadline) return undefined;
  return Object.freeze({
    token,
    claimGeneration,
    listenerGeneration,
    deadline,
  });
}

function sameCredential(
  left: AskClaimCredential | undefined,
  right: AskClaimCredential | undefined,
): boolean {
  return (
    left !== undefined &&
    right !== undefined &&
    left.token === right.token &&
    left.claimGeneration === right.claimGeneration &&
    left.listenerGeneration === right.listenerGeneration &&
    left.deadline === right.deadline
  );
}

function canonicalJsonValue(value: unknown, ancestors: Set<object>): unknown {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return value;
  }
  if (value === undefined) return undefined;
  if (typeof value !== "object") {
    throw new PhoneAskClaimError(
      "phone_ask_answer_payload_invalid",
      "Answer payload must contain only JSON values",
    );
  }
  if (ancestors.has(value)) {
    throw new PhoneAskClaimError(
      "phone_ask_answer_payload_invalid",
      "Answer payload must not contain cycles",
    );
  }
  ancestors.add(value);
  try {
    if (Array.isArray(value)) {
      return value.map((entry) => canonicalJsonValue(entry, ancestors) ?? null);
    }
    if (!isRecord(value)) {
      throw new PhoneAskClaimError(
        "phone_ask_answer_payload_invalid",
        "Answer payload must contain only JSON objects",
      );
    }
    const canonical: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      const entry = canonicalJsonValue(value[key], ancestors);
      if (entry !== undefined) canonical[key] = entry;
    }
    return canonical;
  } finally {
    ancestors.delete(value);
  }
}

function canonicalDigest(value: unknown): string {
  const serialized = JSON.stringify(canonicalJsonValue(value, new Set<object>()));
  if (serialized === undefined) {
    throw new PhoneAskClaimError(
      "phone_ask_answer_payload_invalid",
      "Answer payload must contain a JSON value",
    );
  }
  return crypto.createHash("sha256").update(serialized).digest("hex");
}

function textDigest(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function credentialIsCurrent(
  credential: AskClaimCredential,
  nowMs: number,
): boolean {
  const listenerGeneration = currentListenerGeneration();
  return (
    !deadlineExpired(credential.deadline, nowMs) &&
    listenerGeneration !== undefined &&
    credential.claimGeneration === credential.listenerGeneration &&
    credential.listenerGeneration === listenerGeneration
  );
}

function trackAsk(value: unknown): unknown {
  if (!isRecord(value)) return sanitizeAgentResponseData(value);
  const sanitizedValue = sanitizeAgentResponseData(value);
  const sanitized = isRecord(sanitizedValue) ? sanitizedValue : {};
  delete sanitized.claim_token;

  const askId = stringValue(value.ask_id);
  if (!askId) return sanitized;
  const nowMs = Date.now();
  pruneAskClaimState(nowMs);
  const previous = claimsByAskId.get(askId);
  const sessionId = stringValue(value.session_id) ?? previous?.sessionId;
  const clientTurnId = stringValue(value.client_turn_id) ?? previous?.clientTurnId;
  const answered = value.answered_at != null || value.status === "answered";
  const legacyDrain = value.legacy_drain === true;
  const credentialFieldsPresent = [
    "claim_token",
    "claim_generation",
    "generation",
    "listener_generation",
    "resolved_generation",
    "claim_deadline",
  ].some((field) => Object.prototype.hasOwnProperty.call(value, field));

  let credential = previous?.credential;
  let deferredCredential = previous?.deferredCredential;
  let phase = previous?.phase ?? ("unclaimed" as AskClaimPhase);
  let writeReservation = previous?.writeReservation;
  const answerTerminal = previous?.answerTerminal;
  let lastError = previous?.lastError;

  if (answered) {
    credential = undefined;
    deferredCredential = undefined;
    phase = "settled";
    writeReservation = undefined;
    lastError = undefined;
  } else if (answerTerminal) {
    credential = undefined;
    deferredCredential = undefined;
    phase = "settled";
    writeReservation = undefined;
    lastError = previous?.lastError;
  } else if (legacyDrain) {
    if (writeReservation) {
      phase = "active";
      lastError = "phone_ask_claim_refresh_deferred";
    } else {
      credential = undefined;
      deferredCredential = undefined;
      phase = "legacy-drain";
      writeReservation = undefined;
      lastError = "legacy_ask_drain";
    }
  } else if (credentialFieldsPresent) {
    const nextCredential = credentialFrom(value);
    if (writeReservation) {
      if (
        nextCredential &&
        credentialIsCurrent(nextCredential, nowMs) &&
        value.answerable !== false
      ) {
        if (!sameCredential(writeReservation.credential, nextCredential)) {
          deferredCredential = nextCredential;
        }
        phase = "active";
        lastError = undefined;
      } else {
        phase = "active";
        lastError = "phone_ask_claim_refresh_deferred";
      }
    } else {
      deferredCredential = undefined;
      credential = nextCredential;
      if (!credential) {
        phase = "recoverable";
        lastError = "phone_ask_claim_incomplete";
      } else if (!credentialIsCurrent(credential, nowMs) || value.answerable === false) {
        credential = undefined;
        phase = "recoverable";
        lastError = deadlineExpired(nextCredential?.deadline, nowMs)
          ? "phone_ask_claim_expired"
          : "phone_ask_claim_generation_mismatch";
      } else {
        phase = "active";
        lastError = undefined;
      }
    }
  } else if (credential) {
    if (writeReservation) {
      phase = "active";
    } else if (!credentialIsCurrent(credential, nowMs)) {
      credential = undefined;
      phase = "recoverable";
      writeReservation = undefined;
      lastError = "phone_ask_claim_stale";
    } else {
      phase = "active";
    }
  }

  const claim: StoredAskClaim = {
    askId,
    sessionId,
    clientTurnId,
    credential,
    deferredCredential,
    phase,
    writeReservation,
    answerTerminal,
    updatedAtMs: nowMs,
    lastError,
  };
  saveClaim(claim);
  sanitized.claim_state = phase;
  return sanitized;
}

/** Decode and retain claim authority while returning a recursively token-free response. */
export function trackAgentAskResponse(response: unknown): unknown {
  if (Array.isArray(response)) return response.map(trackAsk);
  if (!isRecord(response) || !Array.isArray(response.asks)) {
    return sanitizeAgentResponseData(response);
  }
  const sanitized = sanitizeAgentResponseData(response);
  const output = isRecord(sanitized) ? sanitized : {};
  return { ...output, asks: response.asks.map(trackAsk) };
}

export function getAskClaimStatus(askId: string): AskClaimStatus | undefined {
  pruneAskClaimState();
  const claim = claimsByAskId.get(askId);
  return claim ? publicStatus(claim) : undefined;
}

export function listAskClaimStatuses(): AskClaimStatus[] {
  pruneAskClaimState();
  return [...claimsByAskId.values()].map(publicStatus);
}

export function hasUnsettledAskClaimForSession(sessionId: string): boolean {
  return claimsForSession(sessionId).length > 0;
}

function claimsForSession(sessionId: string): StoredAskClaim[] {
  pruneAskClaimState();
  return [...(askIdsBySession.get(sessionId) ?? [])]
    .map((askId) => claimsByAskId.get(askId))
    .filter((claim): claim is StoredAskClaim => claim !== undefined && claim.phase !== "settled");
}

function resolveClaim(sessionId: string, askId?: string): StoredAskClaim | undefined {
  if (askId) {
    const claim = claimsByAskId.get(askId);
    if (!claim) {
      throw new PhoneAskClaimError(
        "phone_ask_claim_missing",
        "Ask claim is not available locally; poll get_user_asks before replying",
      );
    }
    if (claim.sessionId && claim.sessionId !== sessionId) {
      throw new PhoneAskClaimError(
        "phone_ask_claim_mismatch",
        "Ask claim belongs to another phone.ask session",
      );
    }
    return claim;
  }

  const claims = claimsForSession(sessionId);
  if (claims.length === 0) return undefined;
  if (claims.length > 1) {
    throw new PhoneAskClaimError(
      "phone_ask_id_required",
      "More than one Ask is pending for this session; provide ask_id",
    );
  }
  return claims[0];
}

function markRecoverable(claim: StoredAskClaim, reason: string): never {
  claim.phase = "recoverable";
  claim.credential = undefined;
  claim.deferredCredential = undefined;
  claim.writeReservation = undefined;
  claim.updatedAtMs = Date.now();
  claim.lastError = reason;
  saveClaim(claim);
  throw new PhoneAskClaimError(
    reason,
    "Ask claim is not currently answerable; re-poll get_user_asks to recover it",
  );
}

function claimedPhoneAskBody(
  body: Record<string, unknown>,
  askId: string,
  credential: AskClaimCredential,
  reservationKind: AskWriteKind,
): Record<string, unknown> {
  const {
    ask_id: _askId,
    in_reply_to_ask_id: _legacyAskId,
    claim_token: _claimToken,
    claim_generation: _claimGeneration,
    generation: _generation,
    listener_generation: _listenerGeneration,
    ...rest
  } = body;
  return {
    ...rest,
    ask_id: askId,
    claim_token: credential.token,
    ...(reservationKind === "progress"
      ? { listener_generation: credential.listenerGeneration }
      : { generation: credential.claimGeneration }),
  };
}

function directAnswerRequestBinding(
  sessionId: string,
  askId: string,
  preparedBody: Record<string, unknown>,
): DirectAskAnswerRequestBinding {
  const idempotencyKey = preparedBody.idempotency_key;
  if (typeof idempotencyKey !== "string" || idempotencyKey.length === 0) {
    throw new PhoneAskClaimError(
      "phone_ask_answer_idempotency_key_required",
      "A claimed Ask answer requires a non-empty idempotency_key",
    );
  }
  const {
    claim_token: _claimToken,
    idempotency_key: _idempotencyKey,
    ...canonicalPayload
  } = preparedBody;
  return Object.freeze({
    identityDigest: canonicalDigest({
      method: "POST",
      route: "session-event",
      session_id: sessionId,
      ask_id: askId,
    }),
    payloadDigest: canonicalDigest(canonicalPayload),
    idempotencyKeyDigest: textDigest(idempotencyKey),
  });
}

function prepareClaimedPhoneAskRequest(
  sessionId: string,
  body: Record<string, unknown>,
  askId: string | undefined,
  reservationKind: AskWriteKind,
): PreparedPhoneAskRequest {
  const claim = resolveClaim(sessionId, askId);
  if (!claim) return { body: { ...body } };
  if (claim.phase === "legacy-drain") {
    throw new PhoneAskClaimError(
      "legacy_ask_drain",
      "Legacy Ask has no claim fence and may only be drained by polling",
    );
  }
  if (claim.phase === "settled") {
    throw new PhoneAskClaimError("phone_ask_settled", "Ask already has an answer");
  }
  if (claim.phase !== "active") {
    markRecoverable(claim, claim.lastError ?? "phone_ask_claim_stale");
  }
  if (claim.writeReservation) {
    const activeKind = claim.writeReservation.kind;
    throw new PhoneAskClaimError(
      activeKind === "answer"
        ? "phone_ask_answer_in_flight"
        : "phone_ask_progress_in_flight",
      `A ${activeKind} write for this Ask is already in flight`,
    );
  }

  const credential = claim.credential;
  if (!credential) markRecoverable(claim, "phone_ask_claim_incomplete");
  if (deadlineExpired(credential.deadline)) {
    markRecoverable(claim, "phone_ask_claim_expired");
  }
  const listenerGeneration = currentListenerGeneration();
  if (
    listenerGeneration === undefined ||
    credential.claimGeneration !== credential.listenerGeneration ||
    credential.listenerGeneration !== listenerGeneration
  ) {
    markRecoverable(claim, "phone_ask_claim_generation_mismatch");
  }

  const reservationToken = crypto.randomUUID();
  claim.writeReservation = Object.freeze({
    ownerToken: reservationToken,
    credential,
    kind: reservationKind,
  });
  claim.updatedAtMs = Date.now();
  saveClaim(claim);

  return {
    askId: claim.askId,
    reservationToken,
    body: claimedPhoneAskBody(body, claim.askId, credential, reservationKind),
  };
}

export function preparePhoneAskRequest(
  sessionId: string,
  body: Record<string, unknown>,
  askId?: string,
): PreparedPhoneAskRequest {
  return beginPhoneAskProgressRequest(sessionId, body, askId);
}

export function beginPhoneAskProgressRequest(
  sessionId: string,
  body: Record<string, unknown>,
  askId?: string,
): PreparedPhoneAskRequest {
  return prepareClaimedPhoneAskRequest(sessionId, body, askId, "progress");
}

export function beginPhoneAskAnswerRequest(
  sessionId: string,
  body: Record<string, unknown>,
  askId?: string,
): PreparedPhoneAskRequest {
  return prepareClaimedPhoneAskRequest(sessionId, body, askId, "answer");
}

export function beginDirectPhoneAskAnswerRequest(
  sessionId: string,
  body: Record<string, unknown>,
  askId?: string,
): PreparedPhoneAskRequest {
  const claim = resolveClaim(sessionId, askId);
  if (!claim) return { body: { ...body } };
  if (claim.phase === "legacy-drain") {
    throw new PhoneAskClaimError(
      "legacy_ask_drain",
      "Legacy Ask has no claim fence and may only be drained by polling",
    );
  }
  if (claim.phase === "settled" || claim.answerTerminal) {
    throw new PhoneAskClaimError("phone_ask_settled", "Ask answer authority is terminal");
  }
  if (claim.phase !== "active") {
    markRecoverable(claim, claim.lastError ?? "phone_ask_claim_stale");
  }

  const existing = claim.writeReservation;
  if (
    existing?.kind === "answer" &&
    existing.directAnswer?.state === "retryable"
  ) {
    const credential = existing.credential;
    const preparedBody = claimedPhoneAskBody(body, claim.askId, credential, "answer");
    const requested = directAnswerRequestBinding(sessionId, claim.askId, preparedBody);
    const bound = existing.directAnswer;
    if (requested.idempotencyKeyDigest !== bound.idempotencyKeyDigest) {
      throw new PhoneAskClaimError(
        "phone_ask_answer_idempotency_key_changed",
        "Retry must use the first answer's exact idempotency_key",
      );
    }
    if (requested.identityDigest !== bound.identityDigest) {
      throw new PhoneAskClaimError(
        "phone_ask_answer_identity_changed",
        "Retry must target the first answer's canonical session and Ask",
      );
    }
    if (requested.payloadDigest !== bound.payloadDigest) {
      throw new PhoneAskClaimError(
        "phone_ask_answer_payload_changed",
        "Retry must use the first answer's exact canonical payload",
      );
    }
    if (!credentialIsCurrent(credential, Date.now())) {
      terminalizeDirectAnswer(
        claim,
        bound,
        "failed-closed",
        "phone_ask_answer_authority_stale",
      );
      saveClaim(claim);
      throw new PhoneAskClaimError(
        "phone_ask_answer_authority_stale",
        "Bound answer authority changed before its retry",
      );
    }

    const reservationToken = crypto.randomUUID();
    claim.writeReservation = Object.freeze({
      ownerToken: reservationToken,
      credential,
      kind: "answer",
      directAnswer: Object.freeze({
        identityDigest: bound.identityDigest,
        payloadDigest: bound.payloadDigest,
        idempotencyKeyDigest: bound.idempotencyKeyDigest,
        state: "in-flight",
        attempt: 2,
      }),
    });
    claim.updatedAtMs = Date.now();
    claim.lastError = undefined;
    saveClaim(claim);
    return {
      askId: claim.askId,
      reservationToken,
      body: preparedBody,
    };
  }

  if (existing) {
    const activeKind = existing.kind;
    throw new PhoneAskClaimError(
      activeKind === "answer"
        ? "phone_ask_answer_in_flight"
        : "phone_ask_progress_in_flight",
      `A ${activeKind} write for this Ask is already in flight`,
    );
  }

  const credential = claim.credential;
  if (!credential) markRecoverable(claim, "phone_ask_claim_incomplete");
  if (!credentialIsCurrent(credential, Date.now())) {
    markRecoverable(
      claim,
      deadlineExpired(credential.deadline)
        ? "phone_ask_claim_expired"
        : "phone_ask_claim_generation_mismatch",
    );
  }

  const preparedBody = claimedPhoneAskBody(body, claim.askId, credential, "answer");
  const binding = directAnswerRequestBinding(sessionId, claim.askId, preparedBody);
  const reservationToken = crypto.randomUUID();
  claim.writeReservation = Object.freeze({
    ownerToken: reservationToken,
    credential,
    kind: "answer",
    directAnswer: Object.freeze({
      ...binding,
      state: "in-flight",
      attempt: 1,
    }),
  });
  claim.updatedAtMs = Date.now();
  claim.lastError = undefined;
  saveClaim(claim);
  return {
    askId: claim.askId,
    reservationToken,
    body: preparedBody,
  };
}

function claimForFailure(sessionId: string, askId?: string): StoredAskClaim | undefined {
  if (askId) return claimsByAskId.get(askId);
  const claims = claimsForSession(sessionId);
  return claims.length === 1 ? claims[0] : undefined;
}

function promoteDeferredCredential(claim: StoredAskClaim): boolean {
  const deferred = claim.deferredCredential;
  claim.deferredCredential = undefined;
  if (!deferred || !credentialIsCurrent(deferred, Date.now())) return false;
  claim.credential = deferred;
  claim.phase = "active";
  claim.lastError = undefined;
  return true;
}

const TRANSIENT_DIRECT_ANSWER_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTUNREACH",
  "EPIPE",
  "ETIMEDOUT",
  "EAI_AGAIN",
  "ENETUNREACH",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_SOCKET",
]);

function errorChain(error: unknown): unknown[] {
  const chain: unknown[] = [];
  const seen = new Set<unknown>();
  let current: unknown = error;
  while (current !== undefined && current !== null && !seen.has(current)) {
    chain.push(current);
    seen.add(current);
    current = isRecord(current) ? current.cause : undefined;
  }
  return chain;
}

function errorStatus(value: unknown): number | undefined {
  if (isRecord(value)) {
    const status = value.status;
    if (typeof status === "number" && Number.isInteger(status)) return status;
    if (typeof status === "string" && /^\d{3}$/.test(status)) return Number(status);
  }
  const message = value instanceof Error
    ? value.message
    : isRecord(value) && typeof value.message === "string"
      ? value.message
      : typeof value === "string"
        ? value
        : "";
  const match = /^\s*(?:HTTP\s+)?(\d{3})\b/i.exec(message);
  return match ? Number(match[1]) : undefined;
}

export function isTransientOrAmbiguousDirectAnswerFailure(error: unknown): boolean {
  const chain = errorChain(error);
  for (const part of chain) {
    const status = errorStatus(part);
    if (status !== undefined) {
      return status === 408 || status === 425 || status === 429 || status >= 500;
    }
  }
  for (const part of chain) {
    const code = isRecord(part) && typeof part.code === "string"
      ? part.code.toUpperCase()
      : undefined;
    if (code && TRANSIENT_DIRECT_ANSWER_CODES.has(code)) return true;
    const name = part instanceof Error
      ? part.name
      : isRecord(part) && typeof part.name === "string"
        ? part.name
        : "";
    if (name === "AbortError" || name === "TimeoutError") return true;
    const message = part instanceof Error
      ? part.message
      : isRecord(part) && typeof part.message === "string"
        ? part.message
        : typeof part === "string"
          ? part
          : "";
    if (
      /(?:fetch failed|temporary network failure|socket hang up|connection (?:reset|closed|terminated)|timed? out|timeout|response (?:body )?(?:truncated|terminated)|unexpected end of json input)/i.test(
        message,
      )
    ) {
      return true;
    }
  }
  return false;
}

export function markDirectPhoneAskAnswerFailure(
  sessionId: string,
  askId: string | undefined,
  error: unknown,
  reservationToken?: string,
): "retryable" | "failed-closed" | false {
  const claim = claimForFailure(sessionId, askId);
  if (!claim) return false;
  const reservation = claim.writeReservation;
  const binding = reservation?.directAnswer;
  if (
    !reservation ||
    reservation.kind !== "answer" ||
    reservation.ownerToken !== reservationToken ||
    !binding ||
    binding.state !== "in-flight"
  ) {
    return false;
  }

  const retryableFailure = isTransientOrAmbiguousDirectAnswerFailure(error);
  if (binding.attempt === 1 && retryableFailure) {
    claim.writeReservation = Object.freeze({
      ...reservation,
      directAnswer: Object.freeze({
        ...binding,
        state: "retryable",
      }),
    });
    claim.updatedAtMs = Date.now();
    claim.lastError = "phone_ask_answer_retryable";
    saveClaim(claim);
    return "retryable";
  }

  terminalizeDirectAnswer(
    claim,
    binding,
    "failed-closed",
    binding.attempt === 2 && retryableFailure
      ? "phone_ask_answer_retry_exhausted"
      : "phone_ask_answer_permanent_failure",
  );
  saveClaim(claim);
  return "failed-closed";
}

export function markPhoneAskClaimFailure(
  sessionId: string,
  askId: string | undefined,
  error: unknown,
  reservationToken?: string,
): boolean {
  const claim = claimForFailure(sessionId, askId);
  if (!claim) return false;
  const reservation = claim.writeReservation;
  if (reservation?.directAnswer) {
    return markDirectPhoneAskAnswerFailure(
      sessionId,
      askId,
      error,
      reservationToken,
    ) !== false;
  }
  if (
    reservationToken !== undefined || reservation !== undefined
  ) {
    if (!reservation || reservation.ownerToken !== reservationToken) return false;
  }
  if (!reservation && reservationToken !== undefined) {
    return false;
  }
  const message = error instanceof Error ? error.message : String(error);
  claim.writeReservation = undefined;
  claim.updatedAtMs = Date.now();
  if (/legacy_ask_drain/i.test(message)) {
    claim.phase = "legacy-drain";
    claim.credential = undefined;
    claim.deferredCredential = undefined;
    claim.lastError = "legacy_ask_drain";
  } else if (/already (?:has an answer|answered)|phone_ask_settled/i.test(message)) {
    claim.phase = "settled";
    claim.credential = undefined;
    claim.deferredCredential = undefined;
    claim.lastError = undefined;
  } else if (/stale|expired|no longer answerable|lease_fenced|generation_mismatch/i.test(message)) {
    claim.credential = undefined;
    if (!promoteDeferredCredential(claim)) {
      claim.phase = "recoverable";
      claim.lastError = "phone_ask_claim_stale";
    }
  } else if (!reservation) {
    return false;
  } else if (!promoteDeferredCredential(claim)) {
    claim.credential = reservation.credential;
    if (credentialIsCurrent(claim.credential, Date.now())) {
      claim.phase = "active";
      claim.lastError = undefined;
    } else {
      claim.credential = undefined;
      claim.phase = "recoverable";
      claim.lastError = "phone_ask_claim_stale";
    }
  }
  saveClaim(claim);
  return true;
}

export function settlePhoneAskClaim(
  sessionId: string,
  askId?: string,
  reservationToken?: string,
): boolean {
  const claim = claimForFailure(sessionId, askId);
  if (!claim) return false;
  const reservation = claim.writeReservation;
  if (
    reservation?.kind === "answer" &&
    reservation.directAnswer?.state === "in-flight" &&
    reservation.ownerToken === reservationToken
  ) {
    terminalizeDirectAnswer(
      claim,
      reservation.directAnswer,
      "delivered",
      undefined,
    );
    saveClaim(claim);
    return true;
  }
  if (
    !reservation ||
    reservation.kind !== "answer" ||
    reservation.ownerToken !== reservationToken
  ) return false;
  claim.phase = "settled";
  claim.credential = undefined;
  claim.deferredCredential = undefined;
  claim.writeReservation = undefined;
  claim.updatedAtMs = Date.now();
  claim.lastError = undefined;
  saveClaim(claim);
  return true;
}

export async function executeDirectPhoneAskAnswer<T>(
  sessionId: string,
  body: Record<string, unknown>,
  askId: string | undefined,
  send: (preparedBody: Record<string, unknown>) => Promise<T>,
): Promise<T> {
  const prepared = beginDirectPhoneAskAnswerRequest(sessionId, body, askId);
  let result: T;
  try {
    result = await send(prepared.body);
  } catch (error) {
    if (prepared.askId) {
      markDirectPhoneAskAnswerFailure(
        sessionId,
        prepared.askId,
        error,
        prepared.reservationToken,
      );
    }
    throw error;
  }

  if (
    prepared.askId &&
    !settlePhoneAskClaim(
      sessionId,
      prepared.askId,
      prepared.reservationToken,
    )
  ) {
    const settlementError = new PhoneAskClaimError(
      "phone_ask_answer_settlement_mismatch",
      "Answer was delivered but local authority could not be settled",
    );
    markDirectPhoneAskAnswerFailure(
      sessionId,
      prepared.askId,
      settlementError,
      prepared.reservationToken,
    );
    throw settlementError;
  }
  return result;
}

export function completePhoneAskProgressRequest(
  sessionId: string,
  askId: string | undefined,
  reservationToken: string | undefined,
): boolean {
  const claim = claimForFailure(sessionId, askId);
  if (!claim) return false;
  const reservation = claim.writeReservation;
  if (
    !reservation ||
    reservation.kind !== "progress" ||
    reservation.ownerToken !== reservationToken
  ) return false;
  claim.writeReservation = undefined;
  claim.updatedAtMs = Date.now();
  if (!promoteDeferredCredential(claim)) {
    claim.credential = reservation.credential;
    if (credentialIsCurrent(claim.credential, Date.now())) {
      claim.phase = "active";
      claim.lastError = undefined;
    } else {
      claim.credential = undefined;
      claim.phase = "recoverable";
      claim.lastError = "phone_ask_claim_stale";
    }
  }
  saveClaim(claim);
  return true;
}

export function resetAskClaimState(): void {
  claimsByAskId.clear();
  askIdsBySession.clear();
}
