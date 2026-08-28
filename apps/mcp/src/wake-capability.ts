import crypto from "node:crypto";
import type { ListenerLeaseFence } from "./thread-binding.js";

export const WAKE_BROKER_URL_ENV = "KNOCK_KNOCK_WAKE_BROKER_URL";
export const WAKE_BROKER_CAPABILITY_ENV = "KNOCK_KNOCK_WAKE_CAPABILITY";
export const WAKE_BROKER_CAPABILITY_HEADER = "X-Knock-Wake-Capability";

export type WakeCapabilityClientConfig = Readonly<{
  brokerUrl: string;
  capability: string;
}>;

export function wakeCapabilityClientConfig(
  env: NodeJS.ProcessEnv = process.env,
): WakeCapabilityClientConfig | null {
  const rawUrl = env[WAKE_BROKER_URL_ENV]?.trim();
  const capability = env[WAKE_BROKER_CAPABILITY_ENV]?.trim();
  if (!rawUrl && !capability) return null;
  if (!rawUrl || !capability || !/^[A-Za-z0-9_-]{43,128}$/.test(capability)) {
    throw new Error("Wake capability configuration is invalid");
  }
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error("Wake broker URL is invalid");
  }
  if (
    parsed.protocol !== "http:" ||
    parsed.hostname !== "127.0.0.1" ||
    !parsed.port ||
    parsed.pathname !== "/" ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error("Wake broker must use an exact IPv4 loopback origin");
  }
  return Object.freeze({
    brokerUrl: parsed.origin,
    capability,
  });
}

export function wakeCapabilityLocalFence(
  config: WakeCapabilityClientConfig,
): ListenerLeaseFence {
  const digest = crypto
    .createHash("sha256")
    .update(config.capability)
    .digest("hex")
    .slice(0, 32);
  return {
    leaseId: `wake_capability_${digest}`,
    generation: 1,
    renewAfterMs: 30_000,
  };
}
