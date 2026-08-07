import { readFileSync } from "node:fs";
import http2 from "node:http2";
import { DatabaseSync } from "node:sqlite";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(resolve(root, "apps/api/package.json"));
const { importPKCS8, SignJWT } = require("jose");

function loadEnv() {
  const text = readFileSync(resolve(root, ".env"), "utf8");
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i < 0) continue;
    const k = t.slice(0, i).trim();
    let v = t.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    if (process.env[k] === undefined) process.env[k] = v;
  }
}
loadEnv();

const keyPath = resolve(root, process.env.APNS_KEY_PATH);
const keyId = process.env.APNS_KEY_ID;
const teamId = process.env.APNS_TEAM_ID;
const bundleId = process.env.APNS_BUNDLE_ID;
const production = process.env.APNS_PRODUCTION === "true";

const db = new DatabaseSync(resolve(root, process.env.DATABASE_PATH || ".data/bridge.db"));
const row = db
  .prepare(
    `SELECT platform, push_token FROM devices
     WHERE platform='ios' AND push_token IS NOT NULL AND length(push_token)=64
     ORDER BY updated_at DESC LIMIT 1`,
  )
  .get();
if (!row?.push_token) {
  console.error("No 64-char APNs device token in DB.");
  process.exit(1);
}

const pem = readFileSync(keyPath, "utf8");
const now = Math.floor(Date.now() / 1000);
const key = await importPKCS8(pem, "ES256");
const jwt = await new SignJWT({})
  .setProtectedHeader({ alg: "ES256", kid: keyId })
  .setIssuer(teamId)
  .setIssuedAt(now)
  .sign(key);

const host = production ? "api.push.apple.com" : "api.sandbox.push.apple.com";
const token = row.push_token;
const body = JSON.stringify({
  aps: { alert: { title: "Knock Knock", body: "Test knock — open Sessions" }, sound: "default" },
  session_id: "ses_apns_test",
});

await new Promise((resolvePromise, reject) => {
  const client = http2.connect(`https://${host}`);
  client.on("error", reject);
  const req = client.request({
    ":method": "POST",
    ":path": `/3/device/${token}`,
    authorization: `bearer ${jwt}`,
    "apns-topic": bundleId,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  });
  let resp = "";
  req.setEncoding("utf8");
  req.on("response", (headers) => {
    const status = Number(headers[":status"] ?? 0);
    req.on("data", (c) => (resp += c));
    req.on("end", () => {
      client.close();
      console.log({
        status,
        resp: resp || null,
        host,
        bundleId,
        targetPlatform: row.platform,
        tokenHint: `${token.slice(0, 8)}…${token.slice(-8)}`,
      });
      if (status >= 200 && status < 300) resolvePromise();
      else reject(new Error(`APNs ${status}: ${resp}`));
    });
  });
  req.on("error", reject);
  req.end(body);
});
