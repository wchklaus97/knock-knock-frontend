#!/usr/bin/env bash
set -euo pipefail

umask 077

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
PUBLIC_KEY_PATH="${KNOCK_MODEL_PUBLIC_KEY_PATH:-}"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_DIRECTORY=""
PRIVATE_PUBLIC_KEY_PATH=""
PRIVATE_INFO_PLIST_PATH=""

fail() {
  printf 'iOS archive failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIRECTORY}" && -d "${TEMP_DIRECTORY}" \
    && "${TEMP_DIRECTORY}" == "${TEMP_ROOT%/}/knock-knock-ios-archive."* ]]; then
    find "${TEMP_DIRECTORY}" -depth -delete
  fi
}
trap cleanup EXIT

# Resolve caller-provided paths before changing into apps/ios. This keeps
# commands such as IOS_EXPORT_OPTIONS_PLIST=apps/ios/ExportOptions-TestFlight-Local.plist
# relative to the repository root, not relative to the iOS project directory.
resolve_project_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT" "$1" ;;
  esac
}

ARCHIVE_PATH="$(resolve_project_path "$ARCHIVE_PATH")"
EXPORT_PATH="$(resolve_project_path "$EXPORT_PATH")"
EXPORT_OPTIONS_PLIST="$(resolve_project_path "$EXPORT_OPTIONS_PLIST")"

command -v xcodebuild >/dev/null || { echo "xcodebuild is required" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "IOS_BUILD_NUMBER is required; pass the next unused App Store Connect build number" >&2
  exit 1
fi
[[ "${PUBLIC_KEY_PATH}" = /* && -f "${PUBLIC_KEY_PATH}" \
  && ! -L "${PUBLIC_KEY_PATH}" && -r "${PUBLIC_KEY_PATH}" ]] \
  || fail "KNOCK_MODEL_PUBLIC_KEY_PATH must be an absolute readable regular file, not a symlink"
TEMP_DIRECTORY="$(mktemp -d "${TEMP_ROOT%/}/knock-knock-ios-archive.XXXXXX")"
PRIVATE_PUBLIC_KEY_PATH="${TEMP_DIRECTORY}/model-public-key.base64"
PRIVATE_INFO_PLIST_PATH="${TEMP_DIRECTORY}/VoiceAgentBridge-Info.plist"
cp "${PUBLIC_KEY_PATH}" "${PRIVATE_PUBLIC_KEY_PATH}"
python3 - \
  "${IOS_DIR}/VoiceAgentBridge/Info.plist" \
  "${PRIVATE_PUBLIC_KEY_PATH}" \
  "${PRIVATE_INFO_PLIST_PATH}" <<'PY'
import pathlib
import plistlib
import sys

source_path = pathlib.Path(sys.argv[1])
key_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])
with source_path.open("rb") as handle:
    payload = plistlib.load(handle)
payload["KNOCK_MODEL_PUBLIC_KEY_BASE64"] = key_path.read_text(
    encoding="utf-8"
).strip()
with output_path.open("wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY
chmod 600 "${PRIVATE_PUBLIC_KEY_PATH}" "${PRIVATE_INFO_PLIST_PATH}"
CONFIGURATION=Release \
  KNOCK_MODEL_PUBLIC_KEY_PATH="${PRIVATE_PUBLIC_KEY_PATH}" \
  INFOPLIST_FILE="${PRIVATE_INFO_PLIST_PATH}" \
  "${ROOT}/scripts/validate-ios-release-model-key.sh" >/dev/null
# Only private temporary paths are passed to Xcode. The target's own Release
# build phase validates that both files contain the same approved public key.
unset KNOCK_MODEL_PUBLIC_KEY_PATH PUBLIC_KEY_PATH

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"
cd "$IOS_DIR"
xcodegen generate
export GIT_LFS_SKIP_SMUDGE="${GIT_LFS_SKIP_SMUDGE:-1}"
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
  "KNOCK_MODEL_PUBLIC_KEY_PATH=${PRIVATE_PUBLIC_KEY_PATH}" \
  "INFOPLIST_FILE=${PRIVATE_INFO_PLIST_PATH}" \
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
