import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  agentEnvCandidates,
  normalizeApiBaseUrl,
  normalizePairingCode,
  pairingFailureMessage,
  resolveAgentEnvPath,
  writeAgentEnvFile,
} from "./cli-support.js";

const syntheticModuleUrl = pathToFileURL(
  "/tmp/knock-knock/apps/mcp/src/cli-support.ts",
).href;

test("long high-entropy pairing codes remain valid", () => {
  assert.equal(normalizePairingCode(" pair_1234567890abcdef "), "pair_1234567890abcdef");
  assert.throws(() => normalizePairingCode("abc"), /4-64/);
  assert.throws(() => normalizePairingCode("x".repeat(65)), /4-64/);
});

test("explicit API URLs are normalized and unsafe forms are rejected", () => {
  assert.equal(normalizeApiBaseUrl("https://staging.example.test///"), "https://staging.example.test");
  assert.throws(() => normalizeApiBaseUrl("file:///tmp/worker"), /http or https/);
  assert.throws(() => normalizeApiBaseUrl("https://user:pass@example.test"), /cannot contain/);
  assert.throws(
    () => normalizeApiBaseUrl("https://staging.example.test/\nINJECTED=value"),
    /line breaks/,
  );
});

test("relative agent env files resolve at the workspace root", () => {
  assert.equal(
    resolveAgentEnvPath(".env.agent", syntheticModuleUrl),
    "/tmp/knock-knock/.env.agent",
  );
  assert.deepEqual(agentEnvCandidates(syntheticModuleUrl), [
    "/tmp/knock-knock/.env.agent",
    "/tmp/knock-knock/apps/mcp/.env.agent",
  ]);
});

test("persisted credentials bind both API aliases and use mode 0600", () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "knock-knock-cli-"));
  const moduleUrl = pathToFileURL(
    path.join(temporaryRoot, "apps/mcp/src/cli-support.ts"),
  ).href;
  fs.mkdirSync(path.join(temporaryRoot, "apps/mcp/src"), { recursive: true });

  const filePath = writeAgentEnvFile(
    ".env.agent",
    "vak_test_key",
    "https://staging.example.test/",
    false,
    moduleUrl,
  );
  const contents = fs.readFileSync(filePath, "utf8");
  assert.match(contents, /^KNOCK_KNOCK_API_URL=https:\/\/staging\.example\.test$/m);
  assert.match(contents, /^BRIDGE_API_URL=https:\/\/staging\.example\.test$/m);
  assert.match(contents, /^BRIDGE_AGENT_KEY=vak_test_key$/m);
  assert.equal(fs.statSync(filePath).mode & 0o777, 0o600);
  assert.throws(
    () =>
      writeAgentEnvFile(
        "invalid.env.agent",
        "vak_test_key\nINJECTED=value",
        "https://staging.example.test/",
        false,
        moduleUrl,
      ),
    /API key is invalid/,
  );

  fs.rmSync(temporaryRoot, { recursive: true });
});

test("404 pairing errors explain environment scoping without echoing the code", () => {
  const message = pairingFailureMessage(
    404,
    "https://staging.example.test",
    "Invalid pairing code",
  );
  assert.match(message, /environment-specific/);
  assert.match(message, /--api-url/);
  assert.doesNotMatch(message, /pair_secret/);
});
