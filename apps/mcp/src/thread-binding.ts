import crypto from "node:crypto";

export type ListenerIdentity = {
  chatId: string;
  chatTitle: string;
  instanceId: string;
};

export type ListenerLeaseFence = {
  leaseId: string;
  generation: number;
  renewAfterMs: number;
};


const chatId = (process.env.CODEX_THREAD_ID ?? process.env.KNOCK_KNOCK_CHAT_ID ?? "").trim();
const configuredTitle = (process.env.KNOCK_KNOCK_CHAT_TITLE ?? "").trim();
const configuredInstanceId = process.env.KNOCK_KNOCK_LISTENER_INSTANCE_ID?.trim();

function listenerInstanceId(): string {
  if (!configuredInstanceId) return crypto.randomUUID();
  if (
    configuredInstanceId.length < 8 ||
    configuredInstanceId.length > 128 ||
    /[\u0000-\u001f\u007f]/.test(configuredInstanceId)
  ) {
    throw new Error("KNOCK_KNOCK_LISTENER_INSTANCE_ID is invalid");
  }
  return configuredInstanceId;
}

export const listenerIdentity: ListenerIdentity | null = chatId
  ? {
      chatId,
      chatTitle: configuredTitle || `Codex thread ${chatId.slice(0, 8)}`,
      instanceId: listenerInstanceId(),
    }
  : null;

let activeListenerLease: ListenerLeaseFence | null = null;

export function setListenerLeaseFence(lease: ListenerLeaseFence | null): void {
  activeListenerLease = lease ? { ...lease } : null;
}

export function currentListenerGeneration(): number | undefined {
  return activeListenerLease?.generation;
}

export function currentListenerLeaseFence(): ListenerLeaseFence | null {
  return activeListenerLease ? { ...activeListenerLease } : null;
}

export function listenerHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  if (listenerIdentity) {
    headers["X-Knock-Chat-ID"] = listenerIdentity.chatId;
    headers["X-Knock-Listener-Instance"] = listenerIdentity.instanceId;
  }
  if (activeListenerLease) {
    headers["X-Knock-Listener-Lease-ID"] = activeListenerLease.leaseId;
    headers["X-Knock-Listener-Generation"] = String(activeListenerLease.generation);
  }
  return headers;
}

export function listenerTakeoverRequested(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  return env.KNOCK_KNOCK_LISTENER_TAKEOVER?.trim().toLowerCase() === "true";
}

export function listenerRegistrationBody(takeover = false) {
  if (!listenerIdentity) {
    throw new Error(
      "Knock Knock voice listening requires CODEX_THREAD_ID or KNOCK_KNOCK_CHAT_ID; refusing an unbound agent-wide listener.",
    );
  }
  return {
    chat_id: listenerIdentity.chatId,
    chat_title: listenerIdentity.chatTitle,
    listener_instance_id: listenerIdentity.instanceId,
    ...(takeover ? { takeover: true } : {}),
  };
}

export function listenerRenewalBody(lease: Pick<ListenerLeaseFence, "leaseId" | "generation">) {
  return {
    lease_id: lease.leaseId,
    generation: lease.generation,
  };
}
