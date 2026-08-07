#!/usr/bin/env bash
# Prepare and trigger the physical-device Knock Knock sign-off.
# The final phone tap remains intentionally human: this script verifies the
# transport, launches the installed binary, and emits one fresh needs_user event.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${BRIDGE_API_URL:-http://127.0.0.1:8787}"
DEVICE_UDID="${KNOCK_DEVICE_UDID:-}"
DEVICE_LABEL="${KNOCK_DEVICE_NAME:-}"
BUNDLE_ID="hk.knockknock.app"
PROJECT_BUILD_VERSION="$(awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT/apps/ios/project.yml")"
EXPECTED_BUNDLE_VERSION="${KNOCK_EXPECTED_BUNDLE_VERSION:-$PROJECT_BUILD_VERSION}"
BUILD_LABEL="build-${EXPECTED_BUNDLE_VERSION}"

if [[ -z "$EXPECTED_BUNDLE_VERSION" ]]; then
  echo "ERROR: set KNOCK_EXPECTED_BUNDLE_VERSION or define CURRENT_PROJECT_VERSION in apps/ios/project.yml." >&2
  exit 2
fi

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_LABEL="${DEVICE_LABEL:-iPhone 13 Pro}"
  DEVICE_UDID="$(xcrun devicectl list devices | awk -v wanted="$DEVICE_LABEL" 'index($0, wanted) { for (i = 1; i <= NF; i++) if (length($i) == 36 && $i ~ /^[0-9A-Fa-f-]+$/) { print $i; exit } }')"
else
  DEVICE_LABEL="${DEVICE_LABEL:-connected iPhone}"
fi
if [[ -z "$DEVICE_UDID" ]]; then
  echo "ERROR: connect $DEVICE_LABEL or set KNOCK_DEVICE_UDID to its device identifier." >&2
  exit 2
fi

echo "== API health =="
HEALTH=$(curl -sf "$API/health")
echo "$HEALTH"

echo "== LAN address =="
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -z "$LAN_IP" ]]; then
  echo "ERROR: no en0 LAN address; connect the Mac and iPhone to the same network." >&2
  exit 1
fi
echo "iPhone API URL should be http://$LAN_IP:8787"

echo "== installed app =="
APP_INFO=$(xcrun devicectl device info apps --device "$DEVICE_UDID" --bundle-id "$BUNDLE_ID")
echo "$APP_INFO"
if ! echo "$APP_INFO" | grep -q "Knock Knock"; then
  echo "ERROR: $BUNDLE_ID is not installed on the device." >&2
  exit 1
fi
if ! echo "$APP_INFO" | awk -v expected="$EXPECTED_BUNDLE_VERSION" \
  '$1 == "Knock" && $2 == "Knock" && $NF == expected { found = 1 } END { exit !found }'; then
  echo "ERROR: expected bundle version $EXPECTED_BUNDLE_VERSION ($BUILD_LABEL)." >&2
  exit 1
fi

echo "== launch $BUILD_LABEL on $DEVICE_LABEL =="
if ! xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"; then
  echo "ERROR: launch failed. Unlock the Mac and iPhone, trust this Mac, then retry." >&2
  exit 2
fi

sleep 2
echo "== trigger fresh agent knock =="
cd "$ROOT"
bash scripts/agent-daily-demo.sh

cat <<'CHECKLIST'

Physical tap checklist:
  1. Confirm the iPhone API URL is the LAN URL printed above.
  2. Confirm Settings shows App $BUILD_LABEL and notification permission is authorized.
  3. Tap Review request on the fresh knock.
  4. Tap rollback, then Confirm in the destructive-action alert.
  5. Run `source scripts/use-agent-env.sh && pnpm --filter @vab/mcp exec tsx src/cli.ts pending`.
  6. Execute the claimed action and submit `result`; confirm the session leaves needs_user.
CHECKLIST
