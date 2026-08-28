import { createRequire } from "node:module";

type MacOSDenyAttachBinding = {
  denyAttach: () => unknown;
};

export type MacOSAntiAttachDependencies = {
  platform: string;
  loadBinding: () => unknown;
};

const require = createRequire(import.meta.url);
const FAILURE_MESSAGE =
  "Refusing to load MCP credentials: macOS anti-attach initialization failed";

function loadNativeBinding(): unknown {
  return require("../build/Release/macos_deny_attach.node");
}

export function installMacOSAntiAttachBoundary({
  platform,
  loadBinding,
}: MacOSAntiAttachDependencies): void {
  if (platform !== "darwin") return;

  try {
    const candidate = loadBinding() as Partial<MacOSDenyAttachBinding> | null;
    if (!candidate || typeof candidate.denyAttach !== "function") {
      throw new Error("invalid native binding");
    }
    if (candidate.denyAttach() !== true) {
      throw new Error("native boundary did not confirm installation");
    }
  } catch {
    throw new Error(FAILURE_MESSAGE);
  }
}

let initialized = false;

export function initializeMacOSAntiAttach(): void {
  if (initialized || process.platform !== "darwin") return;
  installMacOSAntiAttachBoundary({
    platform: process.platform,
    loadBinding: loadNativeBinding,
  });
  initialized = true;
}

initializeMacOSAntiAttach();
