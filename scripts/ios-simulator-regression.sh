#!/usr/bin/env bash
# Deterministic iOS Simulator regression for the production decision surface.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_TEST_DESTINATION"
else
  SIMULATOR_ID="$(xcrun simctl list devices available \
    | sed -n 's/.*iPhone 15 Pro (\([0-9A-Fa-f-]\{36\}\)).*/\1/p' \
    | head -n 1)"
  if [[ -z "$SIMULATOR_ID" ]]; then
    echo "No available iPhone 15 Pro simulator found; set IOS_TEST_DESTINATION explicitly." >&2
    exit 2
  fi
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

# shellcheck disable=SC1091
source "$ROOT/scripts/use-agent-env.sh"

echo "== API health =="
HEALTH="$(curl -sf "${BRIDGE_API_URL}/health")"
echo "$HEALTH" | jq '{ok,api,runtime,version}'
test "$(jq -r '.api // empty' <<<"$HEALTH")" = "rust" || {
  echo "iOS regression must run against the canonical Rust Worker." >&2
  exit 1
}

echo "== create deterministic needs_user fixture =="
cd "$ROOT"
bash scripts/ios-test-fixture.sh

echo "== generate Xcode project =="
cd "$ROOT/apps/ios"
xcodegen generate

echo "== iOS Simulator regression =="
export GIT_LFS_SKIP_SMUDGE="${GIT_LFS_SKIP_SMUDGE:-1}"
xcodebuild \
  -project VoiceAgentBridge.xcodeproj \
  -scheme VoiceAgentBridge \
  -destination "$DESTINATION" \
  KNOCK_API_BASE_URL="$BRIDGE_API_URL" \
  KNOCK_UI_TEST_API_BASE_URL="$BRIDGE_API_URL" \
  test
