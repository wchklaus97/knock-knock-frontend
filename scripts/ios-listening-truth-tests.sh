#!/usr/bin/env bash
# Headless listening-truth gate: no phone, no Worker, no UITests.
# Locks idle Home Listening/Not listening, exclusive 90s window, and Ask 409 mapping.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/apps/ios"
DERIVED="${KNOCK_LISTENING_DERIVED_DATA:-/tmp/knock-listening-truth-tests}"
PREFERRED_UDID="${KNOCK_SIMULATOR_UDID:-830F3979-F680-478F-B77F-85FBA0013A3A}"
RESULT_BUNDLE="${KNOCK_LISTENING_RESULT_BUNDLE:-}"

available_udid_matching() {
  local pattern="$1"
  xcrun simctl list devices available \
    | sed -n "s/.*${pattern} (\([0-9A-Fa-f-]\{36\}\)).*/\1/p" \
    | head -n 1
}

pick_destination() {
  if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
    printf '%s\n' "$IOS_TEST_DESTINATION"
    return
  fi
  if xcrun simctl list devices available | grep -Fq "$PREFERRED_UDID"; then
    printf 'platform=iOS Simulator,id=%s\n' "$PREFERRED_UDID"
    return
  fi
  local se_id iphone16_id any_id
  se_id="$(available_udid_matching 'iPhone SE (3rd generation)')"
  if [[ -n "$se_id" ]]; then
    printf 'platform=iOS Simulator,id=%s\n' "$se_id"
    return
  fi
  iphone16_id="$(available_udid_matching 'iPhone 16')"
  if [[ -n "$iphone16_id" ]]; then
    printf 'platform=iOS Simulator,id=%s\n' "$iphone16_id"
    return
  fi
  any_id="$(xcrun simctl list devices available \
    | sed -n 's/.*iPhone[^(]*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p' \
    | head -n 1)"
  if [[ -z "$any_id" ]]; then
    echo "No available iPhone simulator; set IOS_TEST_DESTINATION." >&2
    exit 2
  fi
  printf 'platform=iOS Simulator,id=%s\n' "$any_id"
}

boot_destination() {
  local destination="$1"
  local udid=""
  if [[ "$destination" =~ id=([0-9A-Fa-f-]{36}) ]]; then
    udid="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$udid" ]]; then
    return
  fi
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
}

DESTINATION="$(pick_destination)"
echo "== listening-truth destination: $DESTINATION =="
boot_destination "$DESTINATION"

cd "$IOS_DIR"
command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is required" >&2
  exit 2
}
xcodegen generate

export KNOCK_SKIP_E5_COPY="${KNOCK_SKIP_E5_COPY:-YES}"
export GIT_LFS_SKIP_SMUDGE="${GIT_LFS_SKIP_SMUDGE:-1}"

xcodebuild_args=(
  test
  -project VoiceAgentBridge.xcodeproj
  -scheme VoiceAgentBridge
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED"
  -skipPackagePluginValidation
  -skipMacroValidation
  -only-testing:VoiceAgentBridgeTests/CantoneseAskWorkflowTests
  -only-testing:VoiceAgentBridgeTests/DynamicVoiceWorkflowTests
  -only-testing:VoiceAgentBridgeTests/BackendCommandPresentationTests
  -skip-testing:VoiceAgentBridgeUITests
)

if [[ -n "$RESULT_BUNDLE" ]]; then
  rm -rf "$RESULT_BUNDLE"
  xcodebuild_args+=(-resultBundlePath "$RESULT_BUNDLE")
fi

if [[ -n "${CI:-}" ]]; then
  xcodebuild_args+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=-
  )
fi

xcodebuild "${xcodebuild_args[@]}"
