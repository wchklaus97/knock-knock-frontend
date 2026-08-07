import { readFileSync, existsSync } from "node:fs";
import http2 from "node:http2";
import { importPKCS8, SignJWT } from "jose";
import { config } from "./config.js";

type ApnsPayload = {
  title: string;
  body: string;
  sessionId: string;
  voiceScript?: string | null;
};

let cachedJwt: { token: string; exp: number } | null = null;
let cachedKey: CryptoKey | null = null;

function apnsConfigured(): boolean {
  return Boolean(
    config.apns.keyPath &&
      config.apns.keyId &&
      config.apns.teamId &&
      config.apns.bundleId &&
      existsSync(config.apns.keyPath),
  );
}

export function isApnsReady(): boolean {
  return apnsConfigured();
}

async function makeJwt(): Promise<string> {
  if (!config.apns.keyPath || !config.apns.keyId || !config.apns.teamId) {
    throw new Error("APNs not configured");
  }
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.exp > now + 60) return cachedJwt.token;

  if (!cachedKey) {
    const pem = readFileSync(config.apns.keyPath, "utf8");
    cachedKey = await importPKCS8(pem, "ES256");
  }

  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.apns.keyId })
    .setIssuer(config.apns.teamId)
    .setIssuedAt(now)
    .sign(cachedKey);

  cachedJwt = { token, exp: now + 3500 };
  return token;
}

/** True for APNs device tokens (64 hex), false for mock sim-/dev- tokens. */
export function looksLikeApnsToken(token: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(token);
}

export async function sendApnsAlert(deviceToken: string, input: ApnsPayload): Promise<void> {
  if (!apnsConfigured()) throw new Error("APNs not configured");

  const host = config.apns.production
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const jwt = await makeJwt();
  const body = JSON.stringify({
    aps: {
      alert: { title: input.title, body: input.body },
      sound: "default",
      category: "KNOCK_DECISION",
    },
    session_id: input.sessionId,
    voice_script: input.voiceScript ?? null,
  });

  await new Promise<void>((resolve, reject) => {
    const client = http2.connect(`https://${host}`);
    const timeout = setTimeout(() => {
      client.close();
      reject(new Error("APNs request timed out"));
    }, 10_000);
    const fail = (err: unknown) => {
      clearTimeout(timeout);
      reject(err);
    };
    client.on("error", fail);

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": config.apns.bundleId!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    });

    let resp = "";
    req.setEncoding("utf8");
    req.on("response", (headers) => {
      const status = Number(headers[":status"] ?? 0);
      req.on("data", (c) => {
        resp += c;
      });
      req.on("end", () => {
        clearTimeout(timeout);
        client.close();
        if (status >= 200 && status < 300) resolve();
        else reject(new Error(`APNs ${status}: ${resp || "no body"}`));
      });
    });
    req.on("error", (err) => {
      clearTimeout(timeout);
      client.close();
      reject(err);
    });
    req.end(body);
  });
}
