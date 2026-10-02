import crypto from "node:crypto";
import http from "node:http";
import type { Socket } from "node:net";
import { claimAgentAsks, type AgentAskRequest } from "./ask-transport.js";
import { listenerAuthorityIsRevoked } from "./listening.js";
import { sanitizeAgentResponseData, sanitizeSensitiveData } from "./redaction.js";
import {
  WAKE_BROKER_CAPABILITY_HEADER,
  type WakeCapabilityClientConfig,
} from "./wake-capability.js";

type RecordValue = Record<string, unknown>;
type ClaimState = "available" | "inflight" | "served";
type TerminalEventAuthorityState =
  | "available"
  | "inflight"
  | "retryable"
  | "settled";

export type WakeCapabilityTerminalReason =
  | "settled"
  | "external"
  | "fenced"
  | "expired"
  | "unavailable"
  | "closed";

export type WakeCapabilityTerminalEvent = Readonly<{
  reason: WakeCapabilityTerminalReason;
}>;

type RealAskCredential = Readonly<{
  token: string;
  generation: number;
  listenerGeneration: number;
}>;

export type WakeCapabilityHandle = WakeCapabilityClientConfig & Readonly<{
  expiresAtMs: number;
  close: () => Promise<void>;
  closed: () => boolean;
  hasActiveResponse: () => boolean;
  whenDrained: (deadlineMs: number) => Promise<"drained" | "forced">;
  settleExternally: () => void;
  revoke: () => void;
  onTerminal: (
    handler: (event: WakeCapabilityTerminalEvent) => void,
  ) => () => void;
}>;

export type WakeCapabilityBrokerOptions = Readonly<{
  askId: string;
  sessionId: string;
  backendRequest: AgentAskRequest;
  requireAuthority: () => void;
  ttlMs?: number;
  now?: () => number;
}>;

const MAX_BODY_BYTES = 64 * 1024;
const LOCAL_GENERATION = 1;
const MAX_TRANSIENT_RETRIES = 1;
export const WAKE_BROKER_FORCE_DRAIN_MS = 1_000;
const SAFE_ROUTE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/;
const OVERRIDE_HEADERS = [
  "x-http-method-override",
  "x-method-override",
  "x-http-method",
  "x-original-url",
  "x-rewrite-url",
  "x-forwarded-uri",
] as const;

class WakeRequestError extends Error {}

function isRecord(value: unknown): value is RecordValue {
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

export function isLoopbackWakePeer(address: string | undefined): boolean {
  return (
    address === "127.0.0.1" ||
    address === "::1" ||
    address === "::ffff:127.0.0.1"
  );
}

function credentialFromAsk(ask: RecordValue): RealAskCredential | null {
  const token = stringValue(ask.claim_token);
  const generation =
    positiveInteger(ask.claim_generation) ?? positiveInteger(ask.generation);
  const listenerGeneration =
    positiveInteger(ask.listener_generation) ?? generation;
  if (!token || !generation || !listenerGeneration) return null;
  return Object.freeze({ token, generation, listenerGeneration });
}

function safeEqual(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return (
    leftBuffer.length === rightBuffer.length &&
    crypto.timingSafeEqual(leftBuffer, rightBuffer)
  );
}

function sendJson(
  response: http.ServerResponse,
  status: number,
  body: RecordValue,
): void {
  if (response.headersSent || response.destroyed) return;
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
    connection: "close",
  });
  response.end(JSON.stringify(body));
}

function sanitizedRecord(value: unknown): RecordValue {
  const sanitized = sanitizeSensitiveData(value);
  return isRecord(sanitized) ? sanitized : { result: sanitized };
}

async function readJson(request: http.IncomingMessage): Promise<RecordValue> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const rawChunk of request) {
    const chunk = Buffer.isBuffer(rawChunk) ? rawChunk : Buffer.from(rawChunk);
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new WakeRequestError("request_body_too_large");
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  let value: unknown;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  } catch {
    throw new WakeRequestError("request_body_invalid");
  }
  if (!isRecord(value)) throw new WakeRequestError("request_body_invalid");
  return value;
}

function assertExactFields(body: RecordValue, allowed: ReadonlySet<string>): void {
  if (Object.keys(body).some((field) => !allowed.has(field))) {
    throw new WakeRequestError("request_fields_invalid");
  }
}

function parseRequestTarget(request: http.IncomingMessage): string {
  const rawTarget = request.url;
  if (
    !rawTarget ||
    !rawTarget.startsWith("/") ||
    rawTarget.startsWith("//") ||
    rawTarget.includes("\\") ||
    rawTarget.includes("%") ||
    OVERRIDE_HEADERS.some((name) => request.headers[name] !== undefined)
  ) {
    throw new WakeRequestError("request_target_invalid");
  }
  let parsed: URL;
  try {
    parsed = new URL(rawTarget, "http://127.0.0.1");
  } catch {
    throw new WakeRequestError("request_target_invalid");
  }
  if (
    parsed.origin !== "http://127.0.0.1" ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash ||
    parsed.pathname !== rawTarget
  ) {
    throw new WakeRequestError("request_target_invalid");
  }
  return parsed.pathname;
}

function isExplicitlyFencedBackendError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /^(?:409)\b|\blease_fenced\b|listener_(?:generation_mismatch|lease_mismatch)/i.test(
    message,
  );
}

function isFencedBackendError(error: unknown): boolean {
  return listenerAuthorityIsRevoked() || isExplicitlyFencedBackendError(error);
}

function backendErrorStatus(error: unknown): number | undefined {
  const message = error instanceof Error ? error.message : String(error);
  const match = /^(\d{3})\b/.exec(message.trim());
  return match ? Number(match[1]) : undefined;
}

function isTransientBackendError(error: unknown): boolean {
  const status = backendErrorStatus(error);
  return (
    status === undefined ||
    status === 408 ||
    status === 429 ||
    (status >= 500 && status <= 599)
  );
}

function canonicalRequestPayload(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalRequestPayload(item)).join(",")}]`;
  }
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .sort()
      .map(
        (key) =>
          `${JSON.stringify(key)}:${canonicalRequestPayload(value[key])}`,
      )
      .join(",")}}`;
  }
  const serialized = JSON.stringify(value);
  if (serialized === undefined) {
    throw new WakeRequestError("request_body_invalid");
  }
  return serialized;
}

function requestIdentity(value: RecordValue): string {
  return crypto
    .createHash("sha256")
    .update(canonicalRequestPayload(value))
    .digest("base64url");
}

export async function createWakeCapabilityBroker(
  options: WakeCapabilityBrokerOptions,
): Promise<WakeCapabilityHandle> {
  const askId = options.askId.trim();
  const sessionId = options.sessionId.trim();
  if (!askId || !SAFE_ROUTE_ID.test(sessionId)) {
    throw new Error("Wake broker target is invalid");
  }
  const ttlMs = options.ttlMs ?? 5 * 60_000;
  if (!Number.isSafeInteger(ttlMs) || ttlMs < 25 || ttlMs > 10 * 60_000) {
    throw new Error("Wake broker TTL is invalid");
  }
  const now = options.now ?? Date.now;
  const expiresAtMs = now() + ttlMs;
  const capability = crypto.randomBytes(32).toString("base64url");
  const localClaimToken = crypto.randomBytes(32).toString("base64url");
  const terminalHandlers = new Set<
    (event: WakeCapabilityTerminalEvent) => void
  >();
  const rawConnectionSockets = new Set<Socket>();
  const activeResponseSockets = new Set<Socket>();
  const drainWaiters = new Set<(result: "drained" | "forced") => void>();
  let credential: RealAskCredential | null = null;
  let claimState: ClaimState = "available";
  let transientClaimFailures = 0;
  let terminalEventAuthorityState: TerminalEventAuthorityState = "available";
  let transientTerminalFailures = 0;
  let terminalRequestIdentity: string | undefined;
  let terminalRequestPayload: string | undefined;
  let terminalIdempotencyKey: string | undefined;
  let terminalEvent: WakeCapabilityTerminalEvent | undefined;
  let closed = false;
  let closePromise: Promise<void> | undefined;
  let expiryTimer: ReturnType<typeof setTimeout> | undefined;
  let forceDrainTimer: ReturnType<typeof setTimeout> | undefined;
  let forceDrainDeadline = Number.POSITIVE_INFINITY;

  const resolveDrainWaiters = (result: "drained" | "forced") => {
    if (rawConnectionSockets.size !== 0) return;
    if (forceDrainTimer) clearTimeout(forceDrainTimer);
    forceDrainTimer = undefined;
    forceDrainDeadline = Number.POSITIVE_INFINITY;
    for (const resolve of drainWaiters) resolve(result);
    drainWaiters.clear();
  };

  const forceDrain = () => {
    if (forceDrainTimer) clearTimeout(forceDrainTimer);
    forceDrainTimer = undefined;
    forceDrainDeadline = Number.POSITIVE_INFINITY;
    const sockets = [...rawConnectionSockets];
    rawConnectionSockets.clear();
    activeResponseSockets.clear();
    for (const resolve of drainWaiters) resolve("forced");
    drainWaiters.clear();
    for (const socket of sockets) socket.destroy();
    server.closeAllConnections?.();
  };

  const scheduleForcedDrain = (deadlineMs: number) => {
    if (
      !Number.isSafeInteger(deadlineMs) ||
      deadlineMs <= 0 ||
      deadlineMs > 30_000
    ) {
      throw new Error("Wake broker drain deadline is invalid");
    }
    if (rawConnectionSockets.size === 0) return;
    const deadline = Date.now() + deadlineMs;
    if (forceDrainTimer && forceDrainDeadline <= deadline) return;
    if (forceDrainTimer) clearTimeout(forceDrainTimer);
    forceDrainDeadline = deadline;
    forceDrainTimer = setTimeout(forceDrain, deadlineMs);
  };

  const trackResponse = (
    request: http.IncomingMessage,
    response: http.ServerResponse,
  ) => {
    const socket = request.socket;
    activeResponseSockets.add(socket);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      activeResponseSockets.delete(socket);
      resolveDrainWaiters("drained");
    };
    socket.once("close", release);
  };

  const whenDrained = (
    deadlineMs: number,
  ): Promise<"drained" | "forced"> => {
    if (
      !Number.isSafeInteger(deadlineMs) ||
      deadlineMs <= 0 ||
      deadlineMs > 30_000
    ) {
      return Promise.reject(new Error("Wake broker drain deadline is invalid"));
    }
    if (rawConnectionSockets.size === 0) return Promise.resolve("drained");
    scheduleForcedDrain(deadlineMs);
    return new Promise((resolve) => drainWaiters.add(resolve));
  };

  const server = http.createServer((request, response) => {
    trackResponse(request, response);
    void handle(request, response).catch(() => {
      request.resume();
      sendJson(response, 400, { code: "wake_request_invalid" });
    });
  });
  server.on("connection", (socket) => {
    rawConnectionSockets.add(socket);
    socket.once("close", () => {
      rawConnectionSockets.delete(socket);
      activeResponseSockets.delete(socket);
      resolveDrainWaiters("drained");
    });
    if (closed || terminalEvent) {
      scheduleForcedDrain(WAKE_BROKER_FORCE_DRAIN_MS);
    }
  });
  server.on("clientError", (_error, socket) => {
    if (socket.destroyed) return;
    socket.end(
      "HTTP/1.1 400 Bad Request\r\n" +
        "Connection: close\r\n" +
        "Content-Type: application/json\r\n" +
        "Content-Length: 31\r\n\r\n" +
        '{"code":"wake_request_invalid"}',
    );
  });

  const startClosing = (): Promise<void> => {
    if (closePromise) return closePromise;
    closed = true;
    if (expiryTimer) clearTimeout(expiryTimer);
    expiryTimer = undefined;
    closePromise = new Promise((resolve) => {
      server.close(() => resolve());
      server.closeIdleConnections?.();
      if (!server.listening) resolve();
    });
    return closePromise;
  };

  const markTerminal = (reason: WakeCapabilityTerminalReason): void => {
    terminalEventAuthorityState = "settled";
    if (!terminalEvent) {
      terminalEvent = Object.freeze({ reason });
      credential = null;
      claimState = "served";
      for (const handler of [...terminalHandlers]) handler(terminalEvent);
      void startClosing();
      scheduleForcedDrain(WAKE_BROKER_FORCE_DRAIN_MS);
      return;
    }
    if (terminalEvent.reason === "settled" && reason !== "settled") {
      terminalEvent = Object.freeze({ reason });
      for (const handler of [...terminalHandlers]) handler(terminalEvent);
      scheduleForcedDrain(WAKE_BROKER_FORCE_DRAIN_MS);
    }
  };

  const close = (): Promise<void> => {
    if (terminalEventAuthorityState !== "settled") {
      markTerminal("closed");
    }
    return startClosing();
  };

  const backendFailure = (
    response: http.ServerResponse,
    error: unknown,
    fencedOverride?: boolean,
  ) => {
    const fenced = fencedOverride ?? isFencedBackendError(error);
    if (fenced) markTerminal("fenced");
    sendJson(response, fenced ? 409 : 502, {
      code: fenced ? "lease_fenced" : "wake_backend_failed",
    });
  };

  async function handle(
    request: http.IncomingMessage,
    response: http.ServerResponse,
  ): Promise<void> {
    try {
      if (!isLoopbackWakePeer(request.socket.remoteAddress)) {
        request.resume();
        sendJson(response, 403, { code: "loopback_required" });
        return;
      }
      const presented = request.headers[WAKE_BROKER_CAPABILITY_HEADER.toLowerCase()];
      if (typeof presented !== "string" || !safeEqual(presented, capability)) {
        request.resume();
        sendJson(response, 401, { code: "wake_capability_invalid" });
        return;
      }
      if (terminalEvent || now() >= expiresAtMs) {
        request.resume();
        if (!terminalEvent) markTerminal("expired");
        sendJson(response, 410, { code: "wake_capability_expired" });
        return;
      }

      const requestPath = parseRequestTarget(request);
      const progressPath = `/v1/sessions/${sessionId}/progress`;
      const eventPath = `/v1/sessions/${sessionId}/events`;

      if (
        request.method === "POST" &&
        requestPath === "/v1/agents/me/asks/claim"
      ) {
        if (claimState === "inflight") {
          request.resume();
          sendJson(response, 409, { code: "wake_claim_inflight" });
          return;
        }
        if (claimState === "served") {
          request.resume();
          sendJson(response, 409, { code: "wake_claim_replayed" });
          return;
        }
        if (
          request.headers["transfer-encoding"] !== undefined ||
          (request.headers["content-length"] !== undefined &&
            request.headers["content-length"] !== "0")
        ) {
          request.resume();
          sendJson(response, 400, { code: "wake_claim_body_forbidden" });
          return;
        }

        request.resume();
        claimState = "inflight";
        let backendResponse: unknown;
        try {
          options.requireAuthority();
          backendResponse = await claimAgentAsks(options.backendRequest);
        } catch (error: unknown) {
          let authorityStillValid = true;
          try {
            options.requireAuthority();
          } catch {
            authorityStillValid = false;
          }
          const fenced =
            isExplicitlyFencedBackendError(error) || !authorityStillValid;
          if (
            !fenced &&
            isTransientBackendError(error) &&
            transientClaimFailures < MAX_TRANSIENT_RETRIES
          ) {
            transientClaimFailures += 1;
            claimState = "available";
          } else {
            claimState = "served";
          }
          backendFailure(response, error, fenced);
          return;
        }
        if (terminalEvent) {
          sendJson(response, 410, { code: "wake_capability_expired" });
          return;
        }
        const backendRecord = isRecord(backendResponse) ? backendResponse : {};
        const asks = Array.isArray(backendRecord.asks) ? backendRecord.asks : [];
        const target = asks.find(
          (value) =>
            isRecord(value) &&
            value.ask_id === askId &&
            value.session_id === sessionId,
        );
        claimState = "served";
        if (!isRecord(target)) {
          markTerminal("unavailable");
          sendJson(response, 404, { code: "wake_ask_unavailable" });
          return;
        }
        credential = credentialFromAsk(target);
        if (!credential) {
          markTerminal("unavailable");
          sendJson(response, 409, { code: "wake_claim_invalid" });
          return;
        }
        const sanitized = sanitizeAgentResponseData(target);
        const safeAsk = isRecord(sanitized) ? sanitized : {};
        sendJson(response, 200, {
          asks: [
            {
              ...safeAsk,
              ask_id: askId,
              session_id: sessionId,
              claim_token: localClaimToken,
              claim_generation: LOCAL_GENERATION,
              generation: LOCAL_GENERATION,
              listener_generation: LOCAL_GENERATION,
              claim_deadline: new Date(expiresAtMs).toISOString(),
              answerable: true,
              legacy_drain: false,
            },
          ],
        });
        return;
      }

      if (request.method === "POST" && requestPath === progressPath) {
        if (terminalEventAuthorityState === "settled") {
          request.resume();
          sendJson(response, 409, { code: "wake_terminal_settled" });
          return;
        }
        const body = await readJson(request);
        assertExactFields(
          body,
          new Set([
            "status",
            "message",
            "percent",
            "facts",
            "ask_id",
            "claim_token",
            "listener_generation",
          ]),
        );
        const requestCredential = credential;
        if (
          claimState !== "served" ||
          !requestCredential ||
          body.ask_id !== askId ||
          body.claim_token !== localClaimToken ||
          body.listener_generation !== LOCAL_GENERATION
        ) {
          sendJson(response, 403, { code: "wake_target_forbidden" });
          return;
        }
        if (terminalEventAuthorityState === "settled") {
          sendJson(response, 409, { code: "wake_terminal_settled" });
          return;
        }
        try {
          options.requireAuthority();
          const result = await options.backendRequest(progressPath, {
            method: "POST",
            json: {
              ...body,
              claim_token: requestCredential.token,
              listener_generation: requestCredential.listenerGeneration,
            },
          });
          sendJson(response, 200, sanitizedRecord(result));
        } catch (error: unknown) {
          backendFailure(response, error);
        }
        return;
      }

      if (request.method === "POST" && requestPath === eventPath) {
        if (terminalEventAuthorityState === "settled") {
          request.resume();
          sendJson(response, 409, { code: "wake_terminal_settled" });
          return;
        }
        const body = await readJson(request);
        assertExactFields(
          body,
          new Set([
            "status",
            "idempotency_key",
            "summary",
            "facts",
            "actions",
            "force_push",
            "ask_id",
            "claim_token",
            "generation",
          ]),
        );
        const status = stringValue(body.status);
        if (!status || !["info", "needs_user", "succeeded", "failed"].includes(status)) {
          throw new WakeRequestError("request_status_invalid");
        }
        const isTerminalStatus =
          status === "info" || status === "succeeded" || status === "failed";
        const requestCredential = credential;
        if (
          claimState !== "served" ||
          !requestCredential ||
          body.ask_id !== askId ||
          body.claim_token !== localClaimToken ||
          body.generation !== LOCAL_GENERATION
        ) {
          sendJson(response, 403, { code: "wake_target_forbidden" });
          return;
        }
        if (terminalEventAuthorityState === "settled") {
          sendJson(response, 409, { code: "wake_terminal_settled" });
          return;
        }
        let outboundBody = body;
        let backendBody: RecordValue;
        let reservedTerminalIdentity: string | undefined;
        let reservedTerminalPayload: string | undefined;
        let reservedIdempotencyKey: string | undefined;
        if (isTerminalStatus) {
          const hasExplicitIdempotencyKey = Object.hasOwn(body, "idempotency_key");
          const explicitIdempotencyKey = stringValue(body.idempotency_key);
          if (hasExplicitIdempotencyKey && !explicitIdempotencyKey) {
            throw new WakeRequestError("request_idempotency_key_invalid");
          }
          const inputIdentity = requestIdentity(body);
          reservedIdempotencyKey =
            explicitIdempotencyKey ??
            `wake_${crypto
              .createHash("sha256")
              .update(`${askId}\0${sessionId}\0${inputIdentity}`)
              .digest("base64url")}`;
          outboundBody = {
            ...body,
            idempotency_key: reservedIdempotencyKey,
          };
          reservedTerminalIdentity = requestIdentity(outboundBody);
          reservedTerminalPayload = canonicalRequestPayload({
            ...outboundBody,
            claim_token: requestCredential.token,
            generation: requestCredential.generation,
          });

          if (terminalEventAuthorityState === "settled") {
            sendJson(response, 409, { code: "wake_terminal_settled" });
            return;
          }
          if (terminalEventAuthorityState === "inflight") {
            sendJson(response, 409, { code: "wake_terminal_inflight" });
            return;
          }
          if (
            terminalEventAuthorityState === "retryable" &&
            (terminalRequestIdentity !== reservedTerminalIdentity ||
              terminalRequestPayload !== reservedTerminalPayload ||
              terminalIdempotencyKey !== reservedIdempotencyKey)
          ) {
            sendJson(response, 409, { code: "wake_terminal_retry_mismatch" });
            return;
          }
          terminalEventAuthorityState = "inflight";
          terminalRequestIdentity = reservedTerminalIdentity;
          terminalRequestPayload = reservedTerminalPayload;
          terminalIdempotencyKey = reservedIdempotencyKey;
          backendBody = JSON.parse(reservedTerminalPayload) as RecordValue;
        } else {
          backendBody = {
            ...outboundBody,
            claim_token: requestCredential.token,
            generation: requestCredential.generation,
          };
        }
        try {
          options.requireAuthority();
          const result = await options.backendRequest(eventPath, {
            method: "POST",
            json: backendBody,
          });
          if (isTerminalStatus) {
            terminalEventAuthorityState = "settled";
            markTerminal("settled");
          }
          sendJson(response, 200, sanitizedRecord(result));
        } catch (error: unknown) {
          if (isTerminalStatus) {
            let authorityStillValid = true;
            try {
              options.requireAuthority();
            } catch {
              authorityStillValid = false;
            }
            const fenced =
              isExplicitlyFencedBackendError(error) || !authorityStillValid;
            const retryReservationMatches =
              terminalEventAuthorityState === "inflight" &&
              terminalRequestIdentity === reservedTerminalIdentity &&
              terminalRequestPayload === reservedTerminalPayload &&
              terminalIdempotencyKey === reservedIdempotencyKey;
            const retryRemains =
              !fenced &&
              isTransientBackendError(error) &&
              transientTerminalFailures < MAX_TRANSIENT_RETRIES &&
              retryReservationMatches;
            if (retryRemains) {
              transientTerminalFailures += 1;
              terminalEventAuthorityState = "retryable";
            } else {
              terminalEventAuthorityState = "settled";
            }
            backendFailure(response, error, fenced);
            if (!fenced && !retryRemains) {
              await whenDrained(WAKE_BROKER_FORCE_DRAIN_MS);
              markTerminal("settled");
            }
          } else {
            backendFailure(response, error);
          }
        }
        return;
      }

      request.resume();
      sendJson(response, 403, { code: "wake_route_forbidden" });
    } catch (error: unknown) {
      request.resume();
      if (error instanceof WakeRequestError || error instanceof TypeError) {
        sendJson(response, 400, { code: "wake_request_invalid" });
      } else {
        sendJson(response, 400, { code: "wake_request_invalid" });
      }
    }
  }

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    await close();
    throw new Error("Wake broker failed to bind loopback");
  }

  expiryTimer = setTimeout(() => markTerminal("expired"), ttlMs);
  if (typeof expiryTimer === "object" && "unref" in expiryTimer) {
    expiryTimer.unref();
  }

  return Object.freeze({
    brokerUrl: `http://127.0.0.1:${address.port}`,
    capability,
    expiresAtMs,
    close,
    closed: () => closed,
    hasActiveResponse: () => rawConnectionSockets.size > 0,
    whenDrained,
    settleExternally: () => {
      if (terminalEventAuthorityState === "settled") return;
      markTerminal("external");
    },
    revoke: () => markTerminal("fenced"),
    onTerminal: (handler: (event: WakeCapabilityTerminalEvent) => void) => {
      if (terminalEvent) {
        const event = terminalEvent;
        queueMicrotask(() => handler(event));
        return () => undefined;
      }
      terminalHandlers.add(handler);
      return () => terminalHandlers.delete(handler);
    },
  });
}
