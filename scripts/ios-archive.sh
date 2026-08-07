#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/apps/ios"
SCHEME="${IOS_SCHEME:-VoiceAgentBridge}"
ARCHIVE_PATH="${IOS_ARCHIVE_PATH:-$ROOT/.derivedData/KnockKnock.xcarchive}"
EXPORT_PATH="${IOS_EXPORT_PATH:-$ROOT/.derivedData/export}"
TEAM_ID="${DEVELOPMENT_TEAM:-TXKDW2YS44}"
BUILD_NUMBER="${IOS_BUILD_NUMBER:-}"
SIGNING_STYLE="${IOS_SIGNING_STYLE:-Manual}"
CODE_SIGN_IDENTITY="${IOS_CODE_SIGN_IDENTITY:-Apple Distribution}"
PROVISIONING_PROFILE="${IOS_PROVISIONING_PROFILE_SPECIFIER:-Knock Knock App Store Distribution}"
EXPORT_OPTIONS_PLIST="${IOS_EXPORT_OPTIONS_PLIST:-$IOS_DIR/ExportOptions-TestFlight.plist}"

command -v xcodebuild >/dev/null || { echo "xcodebuild is required" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "IOS_BUILD_NUMBER is required; pass the next unused App Store Connect build number" >&2
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"
cd "$IOS_DIR"
xcodegen generate
SIGNING_ARGS=(
  "CODE_SIGN_STYLE=$SIGNING_STYLE"
  "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
)
if [[ "$SIGNING_STYLE" == "Manual" ]]; then
  SIGNING_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE")
fi

xcodebuild archive \
  -project VoiceAgentBridge.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${SIGNING_ARGS[@]}"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -exportPath "$EXPORT_PATH"

echo "Archive: $ARCHIVE_PATH"
echo "Export:  $EXPORT_PATH"
echo "Export options: $EXPORT_OPTIONS_PLIST"
echo "The export plist controls whether the IPA is uploaded to App Store Connect."
