import crypto from "node:crypto";

export type ListenerIdentity = {
  chatId: string;
  chatTitle: string;
  instanceId: string;
};

const chatId = (process.env.CODEX_THREAD_ID ?? process.env.KNOCK_KNOCK_CHAT_ID ?? "").trim();
const configuredTitle = (process.env.KNOCK_KNOCK_CHAT_TITLE ?? "").trim();

export const listenerIdentity: ListenerIdentity | null = chatId
  ? {
      chatId,
      chatTitle: configuredTitle || `Codex thread ${chatId.slice(0, 8)}`,
      instanceId: crypto.randomUUID(),
    }
  : null;

export function listenerHeaders(): Record<string, string> {
  if (!listenerIdentity) return {};
  return {
    "X-Knock-Chat-ID": listenerIdentity.chatId,
    "X-Knock-Listener-Instance": listenerIdentity.instanceId,
  };
}

export function listenerRegistrationBody(takeover?: boolean) {
  if (!listenerIdentity) {
    throw new Error(
      "Knock Knock voice listening requires CODEX_THREAD_ID or KNOCK_KNOCK_CHAT_ID; refusing an unbound agent-wide listener.",
    );
  }
  return {
    chat_id: listenerIdentity.chatId,
    chat_title: listenerIdentity.chatTitle,
    listener_instance_id: listenerIdentity.instanceId,
    takeover:
      takeover ?? process.env.KNOCK_KNOCK_LISTENER_TAKEOVER?.trim().toLowerCase() === "true",
  };
}
