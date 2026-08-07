import { config as loadEnv } from "dotenv";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(__dirname, "..");
const REPO_ROOT = resolve(APP_ROOT, "../..");

for (const candidate of [join(REPO_ROOT, ".env"), join(APP_ROOT, ".env")]) {
  if (existsSync(candidate)) {
    loadEnv({ path: candidate });
    break;
  }
}

function resolveDbPath(raw: string): string {
  if (isAbsolute(raw)) return raw;
  return resolve(REPO_ROOT, raw);
}

const databasePath = resolveDbPath(process.env.DATABASE_PATH ?? ".data/bridge.db");
mkdirSync(dirname(databasePath), { recursive: true });

function resolveOptionalPath(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  return isAbsolute(raw) ? raw : resolve(REPO_ROOT, raw);
}

const pushMode = process.env.PUSH_MODE ?? "dev";
if (!(["dev", "apns", "both"] as const).includes(pushMode as "dev" | "apns" | "both")) {
  throw new Error(`Invalid PUSH_MODE: ${pushMode}. Expected dev, apns, or both.`);
}

const jwtSecret = process.env.JWT_SECRET ?? "dev-change-me";
const nodeEnv = process.env.NODE_ENV ?? "development";
const publicBaseUrl = process.env.PUBLIC_BASE_URL ?? "http://127.0.0.1:8787";
const corsOrigin = process.env.CORS_ORIGIN ?? (nodeEnv === "production" ? "" : "*");
if (
  nodeEnv === "production" &&
  (jwtSecret === "dev-change-me" || jwtSecret.length < 32)
) {
  throw new Error("JWT_SECRET must be a random value of at least 32 characters in production.");
}
if (nodeEnv === "production" && (!corsOrigin || corsOrigin === "*")) {
  throw new Error("CORS_ORIGIN must be an explicit origin in production.");
}
if (nodeEnv === "production" && !publicBaseUrl.startsWith("https://")) {
  throw new Error("PUBLIC_BASE_URL must use HTTPS in production.");
}
if (nodeEnv === "production" && pushMode === "dev") {
  throw new Error("PUSH_MODE must be apns or both in production.");
}

export const config = {
  nodeEnv,
  port: Number(process.env.PORT ?? 8787),
  serviceVersion: process.env.SERVICE_VERSION ?? "0.1.0",
  databasePath,
  jwtSecret,
  publicBaseUrl,
  corsOrigin,
  /** dev | apns | both — always keep inbox when not "apns"-only */
  pushMode: pushMode as "dev" | "apns" | "both",
  maxTtlSec: 86_400,
  maxDestructiveSec: 1_800,
  pairingTtlSec: 600,
  accessTokenTtlSec: Number(process.env.ACCESS_TOKEN_TTL_SEC ?? 15 * 60),
  refreshTokenTtlSec: Number(process.env.REFRESH_TOKEN_TTL_SEC ?? 60 * 60 * 24 * 30),
  rateLimit: {
    windowSec: Number(process.env.RATE_LIMIT_WINDOW_SEC ?? 60),
    max: Number(process.env.RATE_LIMIT_MAX ?? (nodeEnv === "production" ? 120 : 600)),
    authMax: Number(process.env.RATE_LIMIT_AUTH_MAX ?? (nodeEnv === "production" ? 12 : 120)),
  },
  trustProxy: process.env.TRUST_PROXY === "true",
  apns: {
    keyPath: resolveOptionalPath(process.env.APNS_KEY_PATH),
    keyId: process.env.APNS_KEY_ID,
    teamId: process.env.APNS_TEAM_ID,
    bundleId: process.env.APNS_BUNDLE_ID ?? "hk.knockknock.app",
    production: process.env.APNS_PRODUCTION === "true",
  },
} as const;

if (nodeEnv === "production" && pushMode !== "dev") {
  const apns = config.apns;
  if (!apns.keyPath || !apns.keyId || !apns.teamId || !existsSync(apns.keyPath)) {
    throw new Error("Production APNs requires APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, and a readable .p8 key.");
  }
  if (!apns.production) {
    throw new Error("APNS_PRODUCTION must be true when NODE_ENV=production.");
  }
}
