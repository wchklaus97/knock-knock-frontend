import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const packageRoot = resolve(dirname(scriptPath), "..");
const sourcePath = resolve(packageRoot, "native/macos_deny_attach.c");
const outputDirectory = resolve(packageRoot, "build/Release");
const outputPath = resolve(outputDirectory, "macos_deny_attach.node");
const XCRUN_PATH = "/usr/bin/xcrun";
const TRUSTED_DEVELOPER_ROOTS = Object.freeze([
  "/Library/Developer/CommandLineTools",
]);
const SAFE_STAGE_ARGUMENT = "--safe-stage-code";
const BUILD_FAILURE_MESSAGE =
  "Cannot build macOS anti-attach boundary: trusted build failed";
const loadNativeAddon = createRequire(import.meta.url);

export const BUILD_STAGES = Object.freeze({
  OUTPUT_PREPARE: "output_prepare",
  ARCHITECTURE: "architecture",
  SOURCE_VALIDATION: "source_validation",
  NODE_HEADERS: "node_headers",
  XCRUN_VALIDATION: "xcrun_validation",
  DEVELOPER_ROOT: "developer_root",
  COMPILER_LOOKUP: "compiler_lookup",
  SDK_LOOKUP: "sdk_lookup",
  TEMPORARY_OUTPUT: "temporary_output",
  COMPILATION: "compilation",
  ADDON_VERIFY: "addon_verify",
  ATOMIC_PUBLISH: "atomic_publish",
  CLEANUP: "cleanup",
});

export class MacOSAntiAttachBuildError extends Error {
  constructor(stage) {
    super(BUILD_FAILURE_MESSAGE);
    this.name = "MacOSAntiAttachBuildError";
    this.stage = stage;
  }
}

export function createBuildEnvironment() {
  return {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG: "C",
    LC_ALL: "C",
  };
}

function failBuild(stage) {
  throw new MacOSAntiAttachBuildError(stage);
}

function canonicalAbsolutePath(candidate, stage) {
  if (
    typeof candidate !== "string" ||
    !isAbsolute(candidate) ||
    candidate.trim() !== candidate ||
    candidate.includes("\0") ||
    candidate.includes("\n") ||
    candidate.includes("\r")
  ) {
    failBuild(stage);
  }

  try {
    const canonical = realpathSync(candidate);
    if (!isAbsolute(canonical)) failBuild(stage);
    return canonical;
  } catch {
    failBuild(stage);
  }
}

function isWithin(parent, candidate) {
  const pathFromParent = relative(parent, candidate);
  return (
    pathFromParent === "" ||
    (pathFromParent !== ".." && !pathFromParent.startsWith(`..${sep}`))
  );
}

function validatedMetadata(candidate, kind, permittedOwners, stage) {
  let metadata;
  try {
    metadata = lstatSync(candidate);
  } catch {
    failBuild(stage);
  }

  if (
    (kind === "file" && !metadata.isFile()) ||
    (kind === "directory" && !metadata.isDirectory()) ||
    metadata.isSymbolicLink() ||
    !permittedOwners.has(metadata.uid) ||
    (metadata.mode & 0o022) !== 0
  ) {
    failBuild(stage);
  }
  return metadata;
}

function trustedSystemPath(candidate, kind, stage) {
  const canonical = canonicalAbsolutePath(candidate, stage);
  let current = canonical;
  while (true) {
    validatedMetadata(
      current,
      current === canonical ? kind : "directory",
      new Set([0]),
      stage,
    );
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return canonical;
}

function localPath(candidate, kind, stage) {
  const canonical = canonicalAbsolutePath(candidate, stage);
  const currentUid = typeof process.getuid === "function" ? process.getuid() : 0;
  validatedMetadata(canonical, kind, new Set([0, currentUid]), stage);
  return canonical;
}

function nodeIncludeDirectory() {
  const candidates = [
    resolve(dirname(process.execPath), "../include/node"),
    "/opt/homebrew/include/node",
    "/usr/local/include/node",
  ];

  for (const candidate of candidates) {
    if (!existsSync(resolve(candidate, "node_api.h"))) continue;
    try {
      const includeDirectory = localPath(
        candidate,
        "directory",
        BUILD_STAGES.NODE_HEADERS,
      );
      const header = localPath(
        resolve(candidate, "node_api.h"),
        "file",
        BUILD_STAGES.NODE_HEADERS,
      );
      if (!isWithin(includeDirectory, header)) continue;
      return includeDirectory;
    } catch {
      // Try the next fixed header location without exposing candidate details.
    }
  }
  failBuild(BUILD_STAGES.NODE_HEADERS);
}

function trustedDeveloperRoot() {
  for (const candidate of TRUSTED_DEVELOPER_ROOTS) {
    try {
      return trustedSystemPath(
        candidate,
        "directory",
        BUILD_STAGES.DEVELOPER_ROOT,
      );
    } catch (error) {
      if (!(error instanceof MacOSAntiAttachBuildError)) {
        failBuild(BUILD_STAGES.DEVELOPER_ROOT);
      }
    }
  }
  failBuild(BUILD_STAGES.DEVELOPER_ROOT);
}

function xcrunPath(argumentsList, kind, environment, stage) {
  const lookup = spawnSync(XCRUN_PATH, argumentsList, {
    cwd: packageRoot,
    encoding: "utf8",
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const candidate = typeof lookup.stdout === "string" ? lookup.stdout.trim() : "";
  if (
    lookup.status !== 0 ||
    lookup.signal !== null ||
    lookup.error ||
    !candidate ||
    candidate.includes("\0") ||
    candidate.includes("\n") ||
    candidate.includes("\r")
  ) {
    failBuild(stage);
  }
  return trustedSystemPath(candidate, kind, stage);
}

function architectureForProcess() {
  if (process.arch === "arm64") return "arm64";
  if (process.arch === "x64") return "x86_64";
  failBuild(BUILD_STAGES.ARCHITECTURE);
}

function verifyTemporaryAddon(temporaryOutputPath) {
  const currentUid = typeof process.getuid === "function" ? process.getuid() : 0;
  const metadata = validatedMetadata(
    temporaryOutputPath,
    "file",
    new Set([currentUid]),
    BUILD_STAGES.ADDON_VERIFY,
  );
  if (metadata.size === 0 || metadata.nlink !== 1) {
    failBuild(BUILD_STAGES.ADDON_VERIFY);
  }

  try {
    const addon = loadNativeAddon(temporaryOutputPath);
    if (typeof addon?.denyAttach !== "function" || addon.denyAttach() !== true) {
      failBuild(BUILD_STAGES.ADDON_VERIFY);
    }
  } catch {
    failBuild(BUILD_STAGES.ADDON_VERIFY);
  }
}

export function buildMacOSDenyAttach() {
  if (process.platform !== "darwin") return;

  let temporaryDirectory;
  let activeStage = BUILD_STAGES.OUTPUT_PREPARE;
  try {
    mkdirSync(outputDirectory, { recursive: true, mode: 0o755 });
    const canonicalPackageRoot = canonicalAbsolutePath(
      packageRoot,
      BUILD_STAGES.OUTPUT_PREPARE,
    );
    const canonicalOutputDirectory = localPath(
      outputDirectory,
      "directory",
      BUILD_STAGES.OUTPUT_PREPARE,
    );
    if (!isWithin(canonicalPackageRoot, canonicalOutputDirectory)) {
      failBuild(BUILD_STAGES.OUTPUT_PREPARE);
    }

    // A failed rebuild must never leave an older security boundary loadable.
    rmSync(outputPath, { force: true });

    activeStage = BUILD_STAGES.ARCHITECTURE;
    const architecture = architectureForProcess();
    activeStage = BUILD_STAGES.SOURCE_VALIDATION;
    const canonicalSourcePath = localPath(
      sourcePath,
      "file",
      BUILD_STAGES.SOURCE_VALIDATION,
    );
    if (!isWithin(canonicalPackageRoot, canonicalSourcePath)) {
      failBuild(BUILD_STAGES.SOURCE_VALIDATION);
    }
    activeStage = BUILD_STAGES.NODE_HEADERS;
    const includeDirectory = nodeIncludeDirectory();
    activeStage = BUILD_STAGES.XCRUN_VALIDATION;
    trustedSystemPath(
      XCRUN_PATH,
      "file",
      BUILD_STAGES.XCRUN_VALIDATION,
    );
    activeStage = BUILD_STAGES.DEVELOPER_ROOT;
    const developerRoot = trustedDeveloperRoot();
    const toolEnvironment = {
      ...createBuildEnvironment(),
      DEVELOPER_DIR: developerRoot,
    };
    activeStage = BUILD_STAGES.COMPILER_LOOKUP;
    const compilerPath = xcrunPath(
      ["--find", "clang"],
      "file",
      toolEnvironment,
      BUILD_STAGES.COMPILER_LOOKUP,
    );
    activeStage = BUILD_STAGES.SDK_LOOKUP;
    const sdkPath = xcrunPath(
      ["--sdk", "macosx", "--show-sdk-path"],
      "directory",
      toolEnvironment,
      BUILD_STAGES.SDK_LOOKUP,
    );

    activeStage = BUILD_STAGES.TEMPORARY_OUTPUT;
    temporaryDirectory = mkdtempSync(
      resolve(canonicalOutputDirectory, ".macos-deny-attach-"),
    );
    chmodSync(temporaryDirectory, 0o700);
    const canonicalTemporaryDirectory = localPath(
      temporaryDirectory,
      "directory",
      BUILD_STAGES.TEMPORARY_OUTPUT,
    );
    const temporaryOutputPath = resolve(
      canonicalTemporaryDirectory,
      "macos_deny_attach.node",
    );

    activeStage = BUILD_STAGES.COMPILATION;
    const compilation = spawnSync(
      compilerPath,
      [
        "-std=c11",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-bundle",
        "-undefined",
        "dynamic_lookup",
        "-isysroot",
        sdkPath,
        "-arch",
        architecture,
        `-I${includeDirectory}`,
        canonicalSourcePath,
        "-o",
        temporaryOutputPath,
      ],
      {
        cwd: canonicalPackageRoot,
        encoding: "utf8",
        env: {
          ...toolEnvironment,
          TMPDIR: canonicalTemporaryDirectory,
        },
        stdio: ["ignore", "ignore", "pipe"],
      },
    );

    if (
      compilation.status !== 0 ||
      compilation.signal !== null ||
      compilation.error
    ) {
      failBuild(BUILD_STAGES.COMPILATION);
    }

    activeStage = BUILD_STAGES.ADDON_VERIFY;
    verifyTemporaryAddon(temporaryOutputPath);
    activeStage = BUILD_STAGES.ATOMIC_PUBLISH;
    renameSync(temporaryOutputPath, outputPath);
  } catch (error) {
    try {
      rmSync(outputPath, { force: true });
    } catch {
      // Preserve the generic fail-closed result below.
    }
    if (error instanceof MacOSAntiAttachBuildError) throw error;
    throw new MacOSAntiAttachBuildError(activeStage);
  } finally {
    if (temporaryDirectory) {
      try {
        rmSync(temporaryDirectory, { recursive: true, force: true });
      } catch {
        try {
          rmSync(outputPath, { force: true });
        } catch {
          // Preserve sanitized cleanup failure below.
        }
        throw new MacOSAntiAttachBuildError(BUILD_STAGES.CLEANUP);
      }
    }
  }
}

function isDirectInvocation() {
  if (!process.argv[1]) return false;
  try {
    return (
      realpathSync(resolve(process.argv[1])) === realpathSync(scriptPath)
    );
  } catch {
    return false;
  }
}

if (isDirectInvocation()) {
  try {
    buildMacOSDenyAttach();
  } catch (error) {
    process.stderr.write(`${BUILD_FAILURE_MESSAGE}\n`);
    if (
      process.argv.slice(2).includes(SAFE_STAGE_ARGUMENT) &&
      error instanceof MacOSAntiAttachBuildError
    ) {
      process.stderr.write(`stage=${error.stage}\n`);
    }
    process.exitCode = 1;
  }
}
