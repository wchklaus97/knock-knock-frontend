import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { installMacOSAntiAttachBoundary } from "./macos-anti-attach.js";

const buildScriptPath = fileURLToPath(
  new URL("../scripts/build-macos-deny-attach.mjs", import.meta.url),
);
const nativeSourcePath = fileURLToPath(
  new URL("../native/macos_deny_attach.c", import.meta.url),
);
const legacyBootstrapPath = fileURLToPath(
  new URL("../../../scripts/use-agent-env.sh", import.meta.url),
);
const listenerLauncherPath = fileURLToPath(
  new URL("../../../scripts/knock-codex-listener.sh", import.meta.url),
);
const paperclipSmokePath = fileURLToPath(
  new URL("./paperclip-smoke.ts", import.meta.url),
);
const installAgentSkillPath = fileURLToPath(
  new URL("../../../scripts/install-agent-skill.sh", import.meta.url),
);
const knockMcpWrapperPath = fileURLToPath(
  new URL("../../../scripts/knock-mcp.sh", import.meta.url),
);

test("macOS anti-attach completes before credential loading may continue", () => {
  const events: string[] = [];
  installMacOSAntiAttachBoundary({
    platform: "darwin",
    loadBinding: () => ({
      denyAttach: () => {
        events.push("anti-attach");
        return true;
      },
    }),
  });
  events.push("credential-load");
  assert.deepEqual(events, ["anti-attach", "credential-load"]);

  const clientSource = fs.readFileSync(
    new URL("./client.ts", import.meta.url),
    "utf8",
  );
  assert.match(
    clientSource,
    /^import "\.\/macos-anti-attach\.js";/,
    "the credential-owning client must install anti-attach as its first import",
  );
});

test("macOS anti-attach fails closed without exposing native error details", () => {
  let error: unknown;
  try {
    installMacOSAntiAttachBoundary({
      platform: "darwin",
      loadBinding: () => {
        throw new Error("fixture-secret-must-not-escape");
      },
    });
  } catch (caught) {
    error = caught;
  }

  assert.ok(error instanceof Error);
  assert.equal(
    error.message,
    "Refusing to load MCP credentials: macOS anti-attach initialization failed",
  );
  assert.doesNotMatch(error.message, /fixture-secret/);
  assert.throws(
    () =>
      installMacOSAntiAttachBoundary({
        platform: "darwin",
        loadBinding: () => ({ denyAttach: () => false }),
      }),
    /macOS anti-attach initialization failed/,
  );

  let nativeSymbolError: unknown;
  try {
    installMacOSAntiAttachBoundary({
      platform: "darwin",
      loadBinding: () => ({
        denyAttach: () => {
          throw new Error("fixture-dlsym-detail-must-not-escape");
        },
      }),
    });
  } catch (caught) {
    nativeSymbolError = caught;
  }
  assert.ok(nativeSymbolError instanceof Error);
  assert.equal(
    nativeSymbolError.message,
    "Refusing to load MCP credentials: macOS anti-attach initialization failed",
  );
  assert.doesNotMatch(nativeSymbolError.message, /dlsym-detail/);
});

test("non-macOS startup does not load the macOS native boundary", () => {
  let loaded = false;
  installMacOSAntiAttachBoundary({
    platform: "linux",
    loadBinding: () => {
      loaded = true;
      return { denyAttach: () => true };
    },
  });
  assert.equal(loaded, false);
});

test("native anti-attach uses the public Darwin dynamic-link boundary", () => {
  const nativeSource = fs.readFileSync(
    new URL("../native/macos_deny_attach.c", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(nativeSource, /sys\/ptrace\.h/);
  assert.match(nativeSource, /dlsym\(RTLD_DEFAULT, "ptrace"\)/);
  assert.match(nativeSource, /#define VAB_PT_DENY_ATTACH 31/);
  assert.match(nativeSource, /_Static_assert/);
});

test("shell launchers never read, export, or preview credential values", () => {
  const legacySource = fs.readFileSync(legacyBootstrapPath, "utf8");
  const listenerSource = fs.readFileSync(listenerLauncherPath, "utf8");
  for (const shellSource of [legacySource, listenerSource]) {
    assert.doesNotMatch(
      shellSource,
      /BRIDGE_AGENT_KEY|KNOCK_KNOCK_AGENT_KEY|AgentKey/,
    );
    assert.doesNotMatch(shellSource, /\$\{[^}\n]+:0:[0-9]+\}/);
  }
  assert.doesNotMatch(legacySource, /(^|\n)\s*(?:source|\.)\s+/);
  assert.match(legacySource, /Legacy environment bootstrap is disabled/);
  assert.match(
    legacySource,
    /exec \/bin\/bash --noprofile --norc "\$listener"/,
  );
  assert.match(listenerSource, /\/usr\/bin\/env -i/);
  assert.match(listenerSource, /normalize_listener_takeover/);
  assert.doesNotMatch(listenerSource, /^set -/);

  const fixturePrefix = "fixture-prefix-must-not-be-logged";
  const sourced = spawnSync(
    "/bin/bash",
    [
      "--noprofile",
      "--norc",
      "-c",
      '. "$1"',
      "legacy-bootstrap-test",
      legacyBootstrapPath,
    ],
    {
      encoding: "utf8",
      env: {
        HOME: os.tmpdir(),
        PATH: "/usr/bin:/bin",
        BRIDGE_AGENT_KEY: fixturePrefix,
        KNOCK_KNOCK_AGENT_KEY: fixturePrefix,
      },
    },
  );
  assert.equal(sourced.status, 1);
  assert.match(sourced.stderr, /Legacy environment bootstrap is disabled/);
  assert.doesNotMatch(`${sourced.stdout}${sourced.stderr}`, new RegExp(fixturePrefix));
});

test("Paperclip child environment is an explicit secret-free allowlist", () => {
  const smokeSource = fs.readFileSync(paperclipSmokePath, "utf8");
  assert.match(smokeSource, /PAPERCLIP_CHILD_ENV_ALLOWLIST/);
  assert.match(smokeSource, /secretFreeChildEnvironment\(process\.env\)/);
  assert.doesNotMatch(smokeSource, /\.\.\.process\.env/);
  assert.doesNotMatch(
    smokeSource,
    /PAPERCLIP_TEST_(?:EMAIL|PASSWORD)[\s\S]*env:\s*\{[\s\S]*PAPERCLIP_TEST_/,
  );
});

test("native builder fixes tool lookup, scrubs inherited environment, and publishes atomically", () => {
  const buildSource = fs.readFileSync(buildScriptPath, "utf8");
  assert.match(buildSource, /const XCRUN_PATH = "\/usr\/bin\/xcrun"/);
  assert.match(buildSource, /\/Library\/Developer\/CommandLineTools/);
  assert.doesNotMatch(buildSource, /process\.env/);
  assert.match(buildSource, /realpathSync/);
  assert.match(buildSource, /metadata\.uid/);
  assert.match(buildSource, /metadata\.mode & 0o022/);
  assert.match(buildSource, /TMPDIR: canonicalTemporaryDirectory/);
  assert.match(buildSource, /--safe-stage-code/);
  assert.match(
    buildSource,
    /realpathSync\(resolve\(process\.argv\[1\]\)\)/,
  );
  assert.match(buildSource, /rmSync\(outputPath, \{ force: true \}\)/);
  assert.match(buildSource, /renameSync\(temporaryOutputPath, outputPath\)/);

  const listenerSource = fs.readFileSync(listenerLauncherPath, "utf8");
  const rebuild = listenerSource.indexOf("build-macos-deny-attach.mjs");
  const verify = listenerSource.indexOf("addon.denyAttach()");
  const launch = listenerSource.lastIndexOf("exec /usr/bin/env -i");
  assert.ok(rebuild >= 0 && verify > rebuild && launch > verify);
});

test(
  "poisoned build environment cannot redirect tools, retain stale addon, or log a key prefix",
  { skip: process.platform !== "darwin" },
  () => {
    const fixtureRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "macos-anti-attach-adversarial-"),
    );
    try {
      const scriptsDirectory = path.join(fixtureRoot, "scripts");
      const nativeDirectory = path.join(fixtureRoot, "native");
      const releaseDirectory = path.join(fixtureRoot, "build", "Release");
      const poisonDirectory = path.join(fixtureRoot, "poison-bin");
      fs.mkdirSync(scriptsDirectory, { recursive: true });
      fs.mkdirSync(nativeDirectory, { recursive: true });
      fs.mkdirSync(releaseDirectory, { recursive: true });
      fs.mkdirSync(poisonDirectory, { recursive: true });

      const fixtureBuildScript = path.join(
        scriptsDirectory,
        "build-macos-deny-attach.mjs",
      );
      fs.copyFileSync(buildScriptPath, fixtureBuildScript);
      fs.copyFileSync(
        nativeSourcePath,
        path.join(nativeDirectory, "macos_deny_attach.c"),
      );

      const staleAddon = path.join(releaseDirectory, "macos_deny_attach.node");
      fs.writeFileSync(staleAddon, "stale-addon-must-not-survive");
      const fakeXcrun = path.join(poisonDirectory, "xcrun");
      fs.writeFileSync(
        fakeXcrun,
        '#!/bin/sh\n/usr/bin/touch "$0.used"\nexit 97\n',
        { mode: 0o700 },
      );

      const fixturePrefix = "fixture-build-prefix-must-not-be-logged";
      const result = spawnSync(
        process.execPath,
        ["--no-addons", fixtureBuildScript, "--safe-stage-code"],
        {
          encoding: "utf8",
          env: {
            HOME: fixtureRoot,
            PATH: poisonDirectory,
            LANG: "C",
            LC_ALL: "C",
            DEVELOPER_DIR: poisonDirectory,
            SDKROOT: poisonDirectory,
            TOOLCHAINS: fixturePrefix,
            CPATH: poisonDirectory,
            C_INCLUDE_PATH: poisonDirectory,
            CPLUS_INCLUDE_PATH: poisonDirectory,
            OBJC_INCLUDE_PATH: poisonDirectory,
            LIBRARY_PATH: poisonDirectory,
            LDFLAGS: fixturePrefix,
            CPPFLAGS: fixturePrefix,
            CFLAGS: fixturePrefix,
            BRIDGE_AGENT_KEY: fixturePrefix,
            KNOCK_KNOCK_AGENT_KEY: fixturePrefix,
          },
        },
      );

      assert.notEqual(result.status, 0);
      assert.equal(fs.existsSync(`${fakeXcrun}.used`), false);
      assert.equal(fs.existsSync(staleAddon), false);
      assert.match(result.stderr, /stage=addon_verify/);
      assert.equal(result.stderr.includes(fixtureRoot), false);
      assert.doesNotMatch(
        `${result.stdout ?? ""}${result.stderr ?? ""}`,
        new RegExp(fixturePrefix),
      );
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true });
    }
  },
);

test("generated host configurations can only invoke a validated absolute MCP wrapper", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "knock-mcp-config-generation-"),
  );
  try {
    const repositoryRoot = path.join(
      fixtureRoot,
      'repository with "quoted" path',
    );
    const scriptsDirectory = path.join(repositoryRoot, "scripts");
    const skillDirectory = path.join(
      repositoryRoot,
      "skills",
      "knock-knock",
    );
    fs.mkdirSync(scriptsDirectory, { recursive: true });
    fs.mkdirSync(skillDirectory, { recursive: true });
    const installer = path.join(scriptsDirectory, "install-agent-skill.sh");
    const wrapper = path.join(scriptsDirectory, "knock-mcp.sh");
    fs.copyFileSync(installAgentSkillPath, installer);
    fs.copyFileSync(knockMcpWrapperPath, wrapper);
    fs.chmodSync(installer, 0o755);
    fs.chmodSync(wrapper, 0o755);
    fs.writeFileSync(path.join(skillDirectory, "SKILL.md"), "fixture skill\n");
    fs.writeFileSync(
      path.join(skillDirectory, "cursor-rule.mdc"),
      "fixture rule\n",
    );

    const home = path.join(fixtureRoot, "home");
    const codexHome = path.join(fixtureRoot, "codex");
    const cursorHome = path.join(fixtureRoot, "cursor");
    const paperclipHome = path.join(fixtureRoot, "paperclip");
    const selectedEnv = path.join(repositoryRoot, "selected agent.env");
    const apiUrl = "http://127.0.0.1:8787/v1?label=%22portable%22";
    const install = spawnSync(
      "/bin/bash",
      [
        "--noprofile",
        "--norc",
        installer,
        "--target",
        "all",
        "--repo",
        repositoryRoot,
        "--api-url",
        apiUrl,
        "--paperclip-home",
        paperclipHome,
      ],
      {
        encoding: "utf8",
        env: {
          PATH: "/usr/bin:/bin",
          HOME: home,
          CODEX_HOME: codexHome,
          CURSOR_HOME: cursorHome,
          KNOCK_KNOCK_AGENT_ENV: selectedEnv,
        },
      },
    );
    assert.equal(install.status, 0, install.stderr);

    const expectedWrapper = fs.realpathSync(wrapper);
    const expectedRoot = fs.realpathSync(repositoryRoot);
    for (const configPath of [
      path.join(cursorHome, "knock-knock-mcp.json"),
      path.join(paperclipHome, "knock-knock-mcp.json"),
    ]) {
      const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
      const server = config.mcpServers["voice-agent-bridge"];
      assert.equal(server.command, expectedWrapper);
      assert.deepEqual(server.args, []);
      assert.equal(server.cwd, expectedRoot);
      assert.deepEqual(server.env, {
        BRIDGE_API_URL: apiUrl,
        KNOCK_KNOCK_AGENT_ENV: selectedEnv,
      });
      assert.notEqual(server.command, "pnpm");
      assert.notEqual(server.command, "node");
    }

    const codexConfig = fs.readFileSync(
      path.join(
        codexHome,
        "skills",
        "knock-knock",
        "voice-agent-bridge.toml",
      ),
      "utf8",
    );
    const tomlString = (value: string) =>
      '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    assert.ok(codexConfig.includes("command = " + tomlString(expectedWrapper)));
    assert.ok(codexConfig.includes("args = []"));
    assert.ok(codexConfig.includes("cwd = " + tomlString(expectedRoot)));
    assert.doesNotMatch(codexConfig, /command = "(?:pnpm|node)"/);

    fs.chmodSync(wrapper, 0o775);
    const insecureHome = path.join(fixtureRoot, "insecure-cursor");
    const insecure = spawnSync(
      "/bin/bash",
      [
        "--noprofile",
        "--norc",
        installer,
        "--target",
        "cursor",
        "--repo",
        repositoryRoot,
      ],
      {
        encoding: "utf8",
        env: {
          PATH: "/usr/bin:/bin",
          HOME: home,
          CURSOR_HOME: insecureHome,
        },
      },
    );
    assert.notEqual(insecure.status, 0);
    assert.equal(
      fs.existsSync(path.join(insecureHome, "knock-knock-mcp.json")),
      false,
    );

    fs.chmodSync(wrapper, 0o755);
    const realWrapper = wrapper + ".real";
    fs.renameSync(wrapper, realWrapper);
    fs.symlinkSync(path.basename(realWrapper), wrapper);
    const symlinkHome = path.join(fixtureRoot, "symlink-cursor");
    const symlinked = spawnSync(
      "/bin/bash",
      [
        "--noprofile",
        "--norc",
        installer,
        "--target",
        "cursor",
        "--repo",
        repositoryRoot,
      ],
      {
        encoding: "utf8",
        env: {
          PATH: "/usr/bin:/bin",
          HOME: home,
          CURSOR_HOME: symlinkHome,
        },
      },
    );
    assert.notEqual(symlinked.status, 0);
    assert.equal(
      fs.existsSync(path.join(symlinkHome, "knock-knock-mcp.json")),
      false,
    );
  } finally {
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  }
});

test(
  "secure MCP wrapper scrubs stale parent credentials before native and module bootstrap",
  { skip: process.platform !== "darwin" },
  () => {
    const fixtureRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "knock-mcp-stale-parent-"),
    );
    try {
      const scriptsDirectory = path.join(fixtureRoot, "scripts");
      const mcpRoot = path.join(fixtureRoot, "apps", "mcp");
      const mcpScripts = path.join(mcpRoot, "scripts");
      const nativeDirectory = path.join(mcpRoot, "native");
      const sourceDirectory = path.join(mcpRoot, "src");
      const binDirectory = path.join(mcpRoot, "node_modules", ".bin");
      fs.mkdirSync(scriptsDirectory, { recursive: true });
      fs.mkdirSync(mcpScripts, { recursive: true });
      fs.mkdirSync(nativeDirectory, { recursive: true });
      fs.mkdirSync(sourceDirectory, { recursive: true });
      fs.mkdirSync(binDirectory, { recursive: true });

      const wrapper = path.join(scriptsDirectory, "knock-mcp.sh");
      fs.copyFileSync(knockMcpWrapperPath, wrapper);
      fs.chmodSync(wrapper, 0o755);
      fs.copyFileSync(
        buildScriptPath,
        path.join(mcpScripts, "build-macos-deny-attach.mjs"),
      );
      fs.copyFileSync(
        nativeSourcePath,
        path.join(nativeDirectory, "macos_deny_attach.c"),
      );
      const indexSource = path.join(sourceDirectory, "index.ts");
      fs.writeFileSync(indexSource, "fixture entry\n");
      const fakeTsx = path.join(binDirectory, "tsx");
      fs.writeFileSync(
        fakeTsx,
        [
          'const fs = require("node:fs");',
          'const input = fs.readFileSync(0, "utf8");',
          'const has = (name) => Object.prototype.hasOwnProperty.call(process.env, name);',
          'fs.writeFileSync("capture.json", JSON.stringify({',
          '  bridgeKeyPresent: has("BRIDGE_AGENT_KEY"),',
          '  knockKeyPresent: has("KNOCK_KNOCK_AGENT_KEY"),',
          '  apiUrl: process.env.BRIDGE_API_URL,',
          '  agentEnv: process.env.KNOCK_KNOCK_AGENT_ENV,',
          '  nodeOptions: process.env.NODE_OPTIONS,',
          '  inheritedCpath: has("CPATH"),',
          '  inheritedDeveloperDir: has("DEVELOPER_DIR"),',
          '  args: process.argv.slice(2)',
          "}));",
          "process.stdout.write(input);",
          "",
        ].join("\n"),
      );
      fs.chmodSync(fakeTsx, 0o755);
      const selectedEnv = path.join(fixtureRoot, "selected.env");
      fs.writeFileSync(selectedEnv, "fixture-only\n", { mode: 0o600 });
      const apiUrl = "http://127.0.0.1:8787";
      const stdioProbe = "mcp-stdio-probe\n";

      const wrapperSource = fs.readFileSync(wrapper, "utf8");
      const firstCredentialScrub = wrapperSource.indexOf(
        "unset BRIDGE_AGENT_KEY",
      );
      const secondCredentialScrub = wrapperSource.indexOf(
        "unset KNOCK_KNOCK_AGENT_KEY",
      );
      const firstBootstrap = wrapperSource.indexOf("repository_root()");
      assert.ok(
        firstCredentialScrub >= 0 &&
          secondCredentialScrub > firstCredentialScrub &&
          firstBootstrap > secondCredentialScrub,
      );
      assert.doesNotMatch(wrapperSource, /NODE_PATH/);

      const run = spawnSync(
        "/bin/bash",
        ["--noprofile", "--norc", wrapper],
        {
          cwd: fixtureRoot,
          input: stdioProbe,
          encoding: "utf8",
          env: {
            PATH: "/usr/bin:/bin",
            BRIDGE_API_URL: apiUrl,
            KNOCK_KNOCK_AGENT_ENV: selectedEnv,
            BRIDGE_AGENT_KEY: "stale-parent-fixture",
            KNOCK_KNOCK_AGENT_KEY: "stale-parent-fixture",
            NODE_OPTIONS: "--require=/fixture/must-not-survive.cjs",
            CPATH: "/fixture/must-not-survive",
            DEVELOPER_DIR: "/fixture/must-not-survive",
          },
        },
      );
      assert.equal(run.status, 0, run.stderr);
      assert.equal(run.stdout, stdioProbe);
      const capture = JSON.parse(
        fs.readFileSync(path.join(fixtureRoot, "capture.json"), "utf8"),
      );
      assert.equal(capture.bridgeKeyPresent, false);
      assert.equal(capture.knockKeyPresent, false);
      assert.equal(capture.inheritedCpath, false);
      assert.equal(capture.inheritedDeveloperDir, false);
      assert.equal(capture.apiUrl, apiUrl);
      assert.equal(capture.agentEnv, selectedEnv);
      assert.equal(capture.nodeOptions, "--no-warnings");
      assert.deepEqual(capture.args, [
        "--no-warnings",
        fs.realpathSync(indexSource),
      ]);
      assert.equal(
        fs.existsSync(
          path.join(
            mcpRoot,
            "build",
            "Release",
            "macos_deny_attach.node",
          ),
        ),
        true,
      );
    } finally {
      fs.rmSync(fixtureRoot, { recursive: true, force: true });
    }
  },
);
