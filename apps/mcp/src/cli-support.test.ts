import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  executeDirectPhoneAskAnswer,
  getAskClaimStatus,
  resetAskClaimState,
  trackAgentAskResponse,
} from "./ask-claims.js";
import {
  MAX_AGENT_ENV_FILE_BYTES,
  MIXED_HOST_CREDENTIALS_HINT,
  agentEnvCandidates,
  boundAgentEnvFileName,
  normalizeApiBaseUrl,
  normalizePairingCode,
  parseAgentEnvText,
  pairingFailureMessage,
  readAgentEnvFile,
  resolveAgentEnvPath,
  sameApiEnvironment,
  selectBoundAgentCredentials,
  scrubAgentCredentialEnvironment,
  validateAgentEnvFilePath,
  writeAgentEnvFile,
} from "./cli-support.js";
import {
  isSensitiveFieldName,
  redactSensitiveText,
  safeErrorMessage,
  sanitizeSensitiveData,
} from "./redaction.js";
import { setListenerLeaseFence } from "./thread-binding.js";

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

test("existing credential files require current-user ownership and private mode", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "knock-knock-credentials-"));
  const filePath = path.join(directory, ".env.agent");
  fs.writeFileSync(filePath, "BRIDGE_AGENT_KEY=vak_private\n", { mode: 0o600 });
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  assert.equal(validateAgentEnvFilePath(filePath), filePath);
  const currentUid = process.getuid?.();
  assert.notEqual(currentUid, undefined);
  assert.throws(
    () => validateAgentEnvFilePath(filePath, { currentUid: (currentUid ?? 0) + 1 }),
    /owned by the current user/,
  );

  fs.chmodSync(filePath, 0o640);
  assert.throws(() => validateAgentEnvFilePath(filePath), /group or other permissions/);
  fs.chmodSync(filePath, 0o600);

  assert.equal(readAgentEnvFile(filePath).text, "BRIDGE_AGENT_KEY=vak_private\n");

  const hardLinkPath = path.join(directory, ".env.agent.hard-link");
  fs.linkSync(filePath, hardLinkPath);
  assert.throws(() => readAgentEnvFile(filePath), /hard-link aliases/);
  fs.unlinkSync(hardLinkPath);

  const symlinkPath = path.join(directory, ".env.agent.link");
  fs.symlinkSync(filePath, symlinkPath);
  assert.throws(() => validateAgentEnvFilePath(symlinkPath), /regular file/);

  const oversizedPath = path.join(directory, ".env.agent.oversized");
  fs.writeFileSync(oversizedPath, "x".repeat(MAX_AGENT_ENV_FILE_BYTES + 1), {
    mode: 0o600,
  });
  assert.throws(() => readAgentEnvFile(oversizedPath), /size limit/);
});

test("credential aliases are scrubbed and client source never assigns AgentKey to process.env", () => {
  const env: NodeJS.ProcessEnv = {
    BRIDGE_AGENT_KEY: "vak_bridge_private",
    KNOCK_KNOCK_AGENT_KEY: "vak_knock_private",
    KNOCK_KNOCK_AGENT_ENV: "/tmp/private-agent.env",
    PATH: "/usr/bin",
  };
  scrubAgentCredentialEnvironment(env);
  assert.deepEqual(env, { PATH: "/usr/bin" });

  const clientSource = fs.readFileSync(new URL("./client.ts", import.meta.url), "utf8");
  assert.doesNotMatch(
    clientSource,
    /process\.env(?:\.(?:BRIDGE_AGENT_KEY|KNOCK_KNOCK_AGENT_KEY)|\[["'](?:BRIDGE_AGENT_KEY|KNOCK_KNOCK_AGENT_KEY)["']\])\s*=/,
  );
});

test(
  "FIFO credential candidates fail closed promptly before metadata validation",
  { skip: process.platform === "win32" },
  (t) => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "knock-knock-fifo-"));
    const fifoPath = path.join(directory, ".env.agent");
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const madeFifo = spawnSync("mkfifo", [fifoPath], { encoding: "utf8" });
    assert.equal(madeFifo.status, 0, "mkfifo fixture creation failed");
    fs.chmodSync(fifoPath, 0o600);

    const moduleUrl = new URL("./cli-support.ts", import.meta.url).href;
    const script = [
      `import { readAgentEnvFile } from ${JSON.stringify(moduleUrl)};`,
      `try { readAgentEnvFile(${JSON.stringify(fifoPath)}); process.exit(70); }`,
      `catch (error) { process.exit(error?.code === "invalid" ? 0 : 71); }`,
    ].join("\n");
    const probe = spawnSync(
      process.execPath,
      ["--import", "tsx", "--input-type=module", "-e", script],
      {
        cwd: path.dirname(fileURLToPath(import.meta.url)),
        encoding: "utf8",
        timeout: 1_500,
      },
    );
    assert.equal(
      (probe.error as NodeJS.ErrnoException | undefined)?.code,
      undefined,
      "credential FIFO probe timed out",
    );
    assert.equal(probe.status, 0, "credential FIFO did not fail closed");
  },
);

test("credential parser accepts only the supported non-executable format", () => {
  assert.deepEqual(
    parseAgentEnvText([
      "# private credential",
      "KNOCK_KNOCK_API_URL=https://staging.example.test",
      "BRIDGE_API_URL=https://staging.example.test/",
      "BRIDGE_AGENT_KEY=vak_safe-key",
      "",
    ].join("\n")),
    { apiUrl: "https://staging.example.test", agentKey: "vak_safe-key" },
  );
  assert.throws(
    () => parseAgentEnvText("BRIDGE_AGENT_KEY=$(touch$IFS/tmp/pwned)\n"),
    /unsafe value/,
  );
  assert.throws(
    () => parseAgentEnvText("export BRIDGE_AGENT_KEY=vak_unsafe\n"),
    /unsupported|malformed/,
  );
  assert.throws(
    () => parseAgentEnvText("UNSUPPORTED_KEY=value\n"),
    /unsupported/,
  );
  assert.throws(
    () => parseAgentEnvText("BRIDGE_AGENT_KEY=first\nBRIDGE_AGENT_KEY=second\n"),
    /repeats/,
  );
});

test("listen launcher delegates secure parsing without sourcing credentials", (t) => {
  const launcherPath = fileURLToPath(
    new URL("../../../scripts/knock-listen.sh", import.meta.url),
  );
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "knock-listen-security-"));
  const binDirectory = path.join(directory, "bin");
  const envPath = path.join(directory, ".env.agent.staging");
  const capturePath = path.join(directory, "capture.txt");
  const markerPath = path.join(directory, "shell-injection-ran");
  fs.mkdirSync(binDirectory);
  fs.writeFileSync(
    path.join(binDirectory, "pnpm"),
    [
      "#!/bin/sh",
      'printf "api=%s\\n" "$BRIDGE_API_URL" > "$VAB_CAPTURE"',
      'printf "env=%s\\n" "$KNOCK_KNOCK_AGENT_ENV" >> "$VAB_CAPTURE"',
      'printf "bridge_key=%s\\n" "${BRIDGE_AGENT_KEY-unset}" >> "$VAB_CAPTURE"',
      'printf "agent_key=%s\\n" "${KNOCK_KNOCK_AGENT_KEY-unset}" >> "$VAB_CAPTURE"',
      'printf "%s\\n" "$@" >> "$VAB_CAPTURE"',
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const stagingUrl = "https://knock-knock-backend-staging.wch-klaus.workers.dev";
  fs.writeFileSync(envPath, [
    `BRIDGE_API_URL=${stagingUrl}`,
    `BRIDGE_AGENT_KEY=$(touch$IFS${markerPath})`,
    "",
  ].join("\n"), { mode: 0o600 });
  const result = spawnSync("bash", [launcherPath], {
    encoding: "utf8",
    env: {
      PATH: `${binDirectory}:/usr/bin:/bin`,
      KNOCK_KNOCK_AGENT_ENV: envPath,
      KNOCK_KNOCK_API_URL: stagingUrl,
      BRIDGE_AGENT_KEY: "must-not-survive",
      KNOCK_KNOCK_AGENT_KEY: "must-not-survive",
      VAB_CAPTURE: capturePath,
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(markerPath), false);
  const capture = fs.readFileSync(capturePath, "utf8");
  assert.match(capture, /api=https:\/\/knock-knock-backend-staging/);
  assert.match(capture, /bridge_key=unset/);
  assert.match(capture, /agent_key=unset/);
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

test("loopback aliases require the same canonical scheme, port, and base path", () => {
  assert.equal(sameApiEnvironment("http://127.0.0.1:8787", "http://localhost:8787"), true);
  assert.equal(
    sameApiEnvironment("http://localhost:8787/api/", "http://[::1]:8787/api"),
    true,
  );
  assert.equal(
    sameApiEnvironment("http://localhost/service", "http://127.0.0.1:80/service/"),
    true,
  );
  assert.equal(
    sameApiEnvironment("https://localhost/service", "https://[::1]:443/service"),
    true,
  );
  assert.equal(
    sameApiEnvironment("http://localhost:8787/api", "http://127.0.0.1:8788/api"),
    false,
  );
  assert.equal(
    sameApiEnvironment("http://localhost:8787/api", "https://127.0.0.1:8787/api"),
    false,
  );
  assert.equal(
    sameApiEnvironment("http://localhost:8787/api", "http://127.0.0.1:8787/other"),
    false,
  );
  assert.equal(
    sameApiEnvironment("http://service.localhost:8787/api", "http://127.0.0.1:8787/api"),
    false,
  );
  assert.equal(
    sameApiEnvironment(
      "http://127.0.0.1:8787",
      "https://knock-knock-backend-staging.wch-klaus.workers.dev",
    ),
    false,
  );
  assert.equal(
    sameApiEnvironment(
      "https://knock-knock-backend-staging.wch-klaus.workers.dev",
      "https://knock-knock-backend-staging.wch-klaus.workers.dev/",
    ),
    true,
  );
  assert.equal(
    sameApiEnvironment(
      "https://knock-knock-backend-production.wch-klaus.workers.dev",
      "https://knock-knock-backend-production.wch-klaus.workers.dev/api",
    ),
    false,
  );
  assert.equal(
    boundAgentEnvFileName("https://knock-knock-backend-staging.wch-klaus.workers.dev"),
    ".env.agent.staging",
  );
});

test("local credential selection binds the exact canonical API identity", () => {
  const localFile = {
    path: "/tmp/.env.agent",
    text: [
      "BRIDGE_API_URL=http://localhost:8787/bridge/",
      "BRIDGE_AGENT_KEY=vak_local_bound",
      "",
    ].join("\n"),
  };
  const accepted = selectBoundAgentCredentials({
    requestedApiUrl: "http://[::1]:8787/bridge",
    files: [localFile],
  });
  assert.ok("agentKey" in accepted);
  assert.equal(accepted.agentKey, "vak_local_bound");

  for (const requestedApiUrl of [
    "http://127.0.0.1:8788/bridge",
    "https://127.0.0.1:8787/bridge",
    "http://127.0.0.1:8787/other",
  ]) {
    const rejected = selectBoundAgentCredentials({
      requestedApiUrl,
      files: [localFile],
    });
    assert.ok(!("agentKey" in rejected), requestedApiUrl);
    assert.deepEqual(rejected.skipped, [localFile.path]);
  }
});

test("legacy local key files without a bound URL fail closed", () => {
  const selected = selectBoundAgentCredentials({
    requestedApiUrl: "http://127.0.0.1:8787",
    files: [
      {
        path: "/tmp/.env.agent.legacy",
        text: "BRIDGE_AGENT_KEY=vak_legacy_unbound\n",
      },
    ],
  });
  assert.ok(!("agentKey" in selected));
  assert.deepEqual(selected.skipped, ["/tmp/.env.agent.legacy"]);
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

test("CLI serialization and errors recursively redact security credentials", () => {
  const value = sanitizeSensitiveData({
    result: {
      claim_token: "claim_cli_private_0001",
      child: {
        lease_id: "lease_cli_private_0001",
        key: "vak_cli_private_0001",
        authorization: "Bearer cli-private-token",
      },
    },
  });
  const serialized = JSON.stringify(value);
  assert.doesNotMatch(serialized, /claim_cli_private|lease_cli_private|vak_cli_private/);
  assert.doesNotMatch(serialized, /cli-private-token/);
  assert.match(serialized, /\[REDACTED\]/);

  const error = redactSensitiveText(
    '500 {"claim_token":"claim_error_private","lease_id":"lease_error_private","api_key":"vak_error_private","authorization":"Bearer auth-private"}',
  );
  assert.doesNotMatch(error, /claim_error_private|lease_error_private|vak_error_private/);
  assert.doesNotMatch(error, /auth-private/);
});

test("secret field-name normalization is specific across common naming styles", () => {
  for (const fieldName of [
    "password",
    "PassPhrase",
    "clientSecret",
    "client_secret",
    "CLIENT-SECRET",
    "privateKey",
    "PRIVATE_KEY",
    "private-key",
    "accessToken",
    "refresh_token",
    "SESSION-TOKEN",
    "apiKey",
  ]) {
    assert.equal(isSensitiveFieldName(fieldName), true, fieldName);
  }

  for (const fieldName of [
    "passwordPolicy",
    "passphraseHint",
    "secretName",
    "privateKeyId",
    "accessTokenExpiresAt",
    "refreshTokenCount",
    "sessionTokenEnabled",
    "apiKeyLabel",
    "content",
  ]) {
    assert.equal(isSensitiveFieldName(fieldName), false, fieldName);
  }
  assert.equal(isSensitiveFieldName("transcript", "agent-response"), false);
});

test("nested arrays and objects redact secret values without erasing response text", () => {
  const transcript =
    "The caller discussed password rotation and secret storage without sharing either.";
  const content = "Explain how an API key label differs from the API key itself.";
  const sanitized = sanitizeSensitiveData(
    {
      batches: [
        {
          credentials: {
            PASSWORD: "SYNTHETIC_PASSWORD_VALUE",
            passPhrase: "SYNTHETIC_PASSPHRASE_VALUE",
            client_secret: "SYNTHETIC_CLIENT_SECRET_VALUE",
            "private-key": "SYNTHETIC_PRIVATE_KEY_VALUE",
          },
        },
        [
          {
            accessToken: "SYNTHETIC_ACCESS_TOKEN_VALUE",
            refresh_token: "SYNTHETIC_REFRESH_TOKEN_VALUE",
            "SESSION-TOKEN": "SYNTHETIC_SESSION_TOKEN_VALUE",
            apiKey: "SYNTHETIC_API_KEY_VALUE",
            secret: "SYNTHETIC_SECRET_VALUE",
          },
        ],
      ],
      transcript,
      content,
    },
    "agent-response",
  );

  assert.deepEqual(sanitized, {
    batches: [
      {
        credentials: {
          PASSWORD: "[REDACTED]",
          passPhrase: "[REDACTED]",
          client_secret: "[REDACTED]",
          "private-key": "[REDACTED]",
        },
      },
      [
        {
          accessToken: "[REDACTED]",
          refresh_token: "[REDACTED]",
          "SESSION-TOKEN": "[REDACTED]",
          apiKey: "[REDACTED]",
          secret: "[REDACTED]",
        },
      ],
    ],
    transcript,
    content,
  });
});

test("stringified diagnostics and errors redact assignments but preserve prose", () => {
  const diagnostic = redactSensitiveText(
    [
      'request failed: {"password":"SYNTHETIC_PASSWORD_TEXT","clientSecret":"SYNTHETIC_CLIENT_SECRET_TEXT"}',
      'nested={"private_key":"SYNTHETIC_PRIVATE_KEY_TEXT","access-token":"SYNTHETIC_ACCESS_TOKEN_TEXT","refreshToken":"SYNTHETIC_REFRESH_TOKEN_TEXT"}',
      "query?session_token=SYNTHETIC_SESSION_TOKEN_TEXT&apiKey=SYNTHETIC_API_KEY_TEXT",
      'content="The caller discussed password rotation and secret storage."',
    ].join(" "),
  );
  for (const syntheticValue of [
    "SYNTHETIC_PASSWORD_TEXT",
    "SYNTHETIC_CLIENT_SECRET_TEXT",
    "SYNTHETIC_PRIVATE_KEY_TEXT",
    "SYNTHETIC_ACCESS_TOKEN_TEXT",
    "SYNTHETIC_REFRESH_TOKEN_TEXT",
    "SYNTHETIC_SESSION_TOKEN_TEXT",
    "SYNTHETIC_API_KEY_TEXT",
  ]) {
    assert.doesNotMatch(diagnostic, new RegExp(syntheticValue));
  }
  assert.match(
    diagnostic,
    /The caller discussed password rotation and secret storage\./,
  );

  const error = safeErrorMessage(
    new Error(
      'upstream payload="{\\"passphrase\\":\\"SYNTHETIC PASSPHRASE TEXT\\",\\"secret\\":\\"SYNTHETIC_SECRET_TEXT\\"}" content="No credential was supplied in the transcript."',
    ),
  );
  assert.doesNotMatch(error, /SYNTHETIC PASSPHRASE TEXT|SYNTHETIC_SECRET_TEXT/);
  assert.match(error, /No credential was supplied in the transcript\./);
});

const DIRECT_ANSWER_GENERATION = 73;
const DIRECT_ANSWER_DEADLINE = "2999-01-01T00:00:00.000Z";

function directAnswerClaim(
  askId: string,
  sessionId: string,
  claimToken: string,
): Record<string, unknown> {
  return {
    ask_id: askId,
    session_id: sessionId,
    client_turn_id: `turn_${askId}`,
    claim_token: claimToken,
    claim_generation: DIRECT_ANSWER_GENERATION,
    listener_generation: DIRECT_ANSWER_GENERATION,
    claim_deadline: DIRECT_ANSWER_DEADLINE,
    answerable: true,
  };
}

function seedDirectAnswerClaim(
  askId: string,
  sessionId: string,
  claimToken = "claim_direct_fixture_private",
): void {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: "lease_direct_fixture",
    generation: DIRECT_ANSWER_GENERATION,
    renewAfterMs: 30_000,
  });
  const visible = trackAgentAskResponse({
    asks: [directAnswerClaim(askId, sessionId, claimToken)],
  });
  assert.doesNotMatch(JSON.stringify(visible), /claim_direct_fixture_private/);
}

function digestPreparedRequest(body: Record<string, unknown>): string {
  return createHash("sha256").update(JSON.stringify(body)).digest("hex");
}

test("DIRECT MCP answer reserves canonical identity, payload, and key before await", async (t) => {
  const askId = "ask_direct_bound_0001";
  const sessionId = "ses_direct_bound_0001";
  seedDirectAnswerClaim(askId, sessionId);
  t.after(() => {
    resetAskClaimState();
    setListenerLeaseFence(null);
  });

  const payload = {
    status: "info",
    idempotency_key: "direct-answer-key-0001",
    summary: "Bound answer",
    facts: { outcome: "ready" },
  };
  let backendCalls = 0;
  let firstRequestDigest: string | undefined;
  const logicalDeliveries = new Set<string>();
  const send = async (preparedBody: Record<string, unknown>) => {
    backendCalls += 1;
    assert.equal(getAskClaimStatus(askId)?.answerInFlight, true);
    const requestDigest = digestPreparedRequest(preparedBody);
    if (firstRequestDigest === undefined) firstRequestDigest = requestDigest;
    else assert.equal(requestDigest, firstRequestDigest);
    logicalDeliveries.add(String(preparedBody.idempotency_key));
    if (backendCalls === 1) {
      const lostResponse = new Error("The operation timed out after dispatch");
      lostResponse.name = "TimeoutError";
      throw lostResponse;
    }
    return { accepted: true };
  };

  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, undefined, send),
    /timed out after dispatch/,
  );
  assert.equal(backendCalls, 1);
  assert.equal(getAskClaimStatus(askId)?.answerInFlight, false);

  await assert.rejects(
    executeDirectPhoneAskAnswer("ses_direct_changed", payload, askId, send),
    /phone_ask_claim_mismatch/,
  );
  await assert.rejects(
    executeDirectPhoneAskAnswer(
      sessionId,
      { ...payload, summary: "Changed answer" },
      askId,
      send,
    ),
    /phone_ask_answer_payload_changed/,
  );
  await assert.rejects(
    executeDirectPhoneAskAnswer(
      sessionId,
      { ...payload, idempotency_key: "direct-answer-key-changed" },
      askId,
      send,
    ),
    /phone_ask_answer_idempotency_key_changed/,
  );
  assert.equal(backendCalls, 1);

  assert.deepEqual(
    await executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    { accepted: true },
  );
  assert.equal(backendCalls, 2);
  assert.equal(logicalDeliveries.size, 1);
  assert.equal(getAskClaimStatus(askId)?.phase, "settled");
  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /phone_ask_settled/,
  );
  assert.equal(backendCalls, 2);
});

test("DIRECT MCP answer exhausts after one identical transient retry", async (t) => {
  const askId = "ask_direct_exhausted_0001";
  const sessionId = "ses_direct_exhausted_0001";
  seedDirectAnswerClaim(askId, sessionId);
  t.after(() => {
    resetAskClaimState();
    setListenerLeaseFence(null);
  });
  const payload = {
    status: "info",
    idempotency_key: "direct-answer-key-exhausted",
    summary: "Retry exactly once",
  };
  let backendCalls = 0;
  const send = async () => {
    backendCalls += 1;
    throw new Error("503 /v1/sessions/test/events: request failed");
  };

  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /^Error: 503/,
  );
  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /^Error: 503/,
  );
  assert.equal(backendCalls, 2);
  assert.equal(getAskClaimStatus(askId)?.phase, "settled");
  assert.equal(
    getAskClaimStatus(askId)?.lastError,
    "phone_ask_answer_retry_exhausted",
  );

  const visible = trackAgentAskResponse({
    asks: [directAnswerClaim(askId, sessionId, "claim_direct_refreshed_private")],
  }) as { asks: Array<Record<string, unknown>> };
  assert.equal(visible.asks[0]?.claim_state, "settled");
  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /phone_ask_settled/,
  );
  assert.equal(backendCalls, 2);
});

test("DIRECT MCP answer fails closed immediately on permanent failure", async (t) => {
  const askId = "ask_direct_permanent_0001";
  const sessionId = "ses_direct_permanent_0001";
  seedDirectAnswerClaim(askId, sessionId);
  t.after(() => {
    resetAskClaimState();
    setListenerLeaseFence(null);
  });
  const payload = {
    status: "info",
    idempotency_key: "direct-answer-key-permanent",
    summary: "Permanent rejection",
  };
  let backendCalls = 0;
  const send = async () => {
    backendCalls += 1;
    throw new Error("422 /v1/sessions/test/events: request failed");
  };

  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /^Error: 422/,
  );
  assert.equal(backendCalls, 1);
  assert.equal(getAskClaimStatus(askId)?.phase, "settled");
  assert.equal(
    getAskClaimStatus(askId)?.lastError,
    "phone_ask_answer_permanent_failure",
  );
  await assert.rejects(
    executeDirectPhoneAskAnswer(sessionId, payload, askId, send),
    /phone_ask_settled/,
  );
  assert.equal(backendCalls, 1);
});

test("DIRECT MCP answer guard leaves generic report_event writes compatible", async () => {
  resetAskClaimState();
  setListenerLeaseFence(null);
  let backendCalls = 0;
  const send = async (preparedBody: Record<string, unknown>) => {
    backendCalls += 1;
    return preparedBody.idempotency_key;
  };

  assert.equal(
    await executeDirectPhoneAskAnswer(
      "ses_generic_direct_0001",
      { status: "info", idempotency_key: "generic-key-0001" },
      undefined,
      send,
    ),
    "generic-key-0001",
  );
  assert.equal(
    await executeDirectPhoneAskAnswer(
      "ses_generic_direct_0001",
      { status: "info", idempotency_key: "generic-key-0002" },
      undefined,
      send,
    ),
    "generic-key-0002",
  );
  assert.equal(backendCalls, 2);
});
