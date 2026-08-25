import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  MIXED_HOST_CREDENTIALS_HINT,
  agentEnvCandidates,
  boundAgentEnvFileName,
  normalizeApiBaseUrl,
  normalizePairingCode,
  pairingFailureMessage,
  resolveAgentEnvPath,
  sameApiEnvironment,
  selectBoundAgentCredentials,
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
  const previous = process.env.KNOCK_KNOCK_AGENT_ENV;
  delete process.env.KNOCK_KNOCK_AGENT_ENV;
  try {
    assert.equal(
      resolveAgentEnvPath(".env.agent", syntheticModuleUrl),
      "/tmp/knock-knock/.env.agent",
    );
    assert.deepEqual(agentEnvCandidates(syntheticModuleUrl), [
      "/tmp/knock-knock/.env.agent",
      "/tmp/knock-knock/.env.agent.staging",
      "/tmp/knock-knock/.env.agent.production",
      "/tmp/knock-knock/apps/mcp/.env.agent",
    ]);
  } finally {
    if (previous === undefined) delete process.env.KNOCK_KNOCK_AGENT_ENV;
    else process.env.KNOCK_KNOCK_AGENT_ENV = previous;
  }
});

test("KNOCK_KNOCK_AGENT_ENV is a fallback after the workspace env file", () => {
  const previous = process.env.KNOCK_KNOCK_AGENT_ENV;
  process.env.KNOCK_KNOCK_AGENT_ENV = "/tmp/override.env.agent";
  try {
    assert.deepEqual(agentEnvCandidates(syntheticModuleUrl), [
      "/tmp/knock-knock/.env.agent",
      "/tmp/override.env.agent",
      "/tmp/knock-knock/.env.agent.staging",
      "/tmp/knock-knock/.env.agent.production",
      "/tmp/knock-knock/apps/mcp/.env.agent",
    ]);
    assert.deepEqual(
      agentEnvCandidates(
        syntheticModuleUrl,
        "https://knock-knock-backend-staging.wch-klaus.workers.dev",
      ),
      [
        "/tmp/knock-knock/.env.agent.staging",
        "/tmp/override.env.agent",
        "/tmp/knock-knock/.env.agent",
        "/tmp/knock-knock/apps/mcp/.env.agent",
      ],
    );
  } finally {
    if (previous === undefined) delete process.env.KNOCK_KNOCK_AGENT_ENV;
    else process.env.KNOCK_KNOCK_AGENT_ENV = previous;
  }
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

test("localhost and loopback are one local environment; staging is not", () => {
  assert.equal(sameApiEnvironment("http://127.0.0.1:8787", "http://localhost:8787"), true);
  assert.equal(
    sameApiEnvironment(
      "http://127.0.0.1:8787",
      "https://knock-knock-backend-staging.wch-klaus.workers.dev",
    ),
    false,
  );
  assert.equal(
    boundAgentEnvFileName("https://knock-knock-backend-staging.wch-klaus.workers.dev"),
    ".env.agent.staging",
  );
});

test("staging API refuses a local agent key file instead of mixing hosts", () => {
  const selected = selectBoundAgentCredentials({
    requestedApiUrl: "https://knock-knock-backend-staging.wch-klaus.workers.dev",
    files: [
      {
        path: "/tmp/.env.agent",
        text: [
          "BRIDGE_API_URL=http://127.0.0.1:8787",
          "BRIDGE_AGENT_KEY=vak_local_only",
          "",
        ].join("\n"),
      },
    ],
  });
  assert.ok(!("agentKey" in selected));
  assert.ok("hint" in selected);
  assert.equal(selected.hint, MIXED_HOST_CREDENTIALS_HINT);
  assert.doesNotMatch(MIXED_HOST_CREDENTIALS_HINT, /vak_/);
});

test("staging API loads only a staging-bound key file", () => {
  const selected = selectBoundAgentCredentials({
    requestedApiUrl: "https://knock-knock-backend-staging.wch-klaus.workers.dev",
    files: [
      {
        path: "/tmp/.env.agent",
        text: "BRIDGE_API_URL=http://127.0.0.1:8787\nBRIDGE_AGENT_KEY=vak_local_only\n",
      },
      {
        path: "/tmp/.env.agent.staging",
        text: [
          "BRIDGE_API_URL=https://knock-knock-backend-staging.wch-klaus.workers.dev",
          "BRIDGE_AGENT_KEY=vak_staging_only",
          "",
        ].join("\n"),
      },
    ],
  });
  assert.ok("path" in selected);
  assert.equal(selected.path, "/tmp/.env.agent.staging");
  assert.equal(selected.agentKey, "vak_staging_only");
});
