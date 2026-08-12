#!/usr/bin/env bash
set -euo pipefail

umask 077

BUNDLE_ID=hk.knockknock.app
DEVICE_TARGET_DIRECTORY=Documents/KnockKnockVoiceAudioUAT
device_id=${KNOCK_DEVICE_UDID:-}
dataset_root=${KNOCK_VOICE_AUDIO_DATASET_ROOT:-}
temporary_root=${TMPDIR:-/tmp}
temporary_directory=

fail() {
  printf 'ios voice-audio UAT staging failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" \
    && "$temporary_directory" == "${temporary_root%/}/knock-knock-voice-audio-uat."* ]]; then
    find "$temporary_directory" -depth -delete
  fi
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    --device)
      (($# >= 2)) || fail "--device requires a value"
      device_id=$2
      shift 2
      ;;
    --dataset-root)
      (($# >= 2)) || fail "--dataset-root requires a value"
      dataset_root=$2
      shift 2
      ;;
    *)
      fail "usage: $0 --device CORE_DEVICE_UUID --dataset-root ABSOLUTE_DATASET_ROOT"
      ;;
  esac
done

for command_name in xcrun jq shasum mktemp; do
  command -v "$command_name" >/dev/null || fail "$command_name is required"
done
[[ "$device_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
  || fail "--device must be a CoreDevice UUID"
[[ "$dataset_root" = /* && -d "$dataset_root" && ! -L "$dataset_root" ]] \
  || fail "--dataset-root must be an absolute, non-symlink directory"

dataset_path="$dataset_root/KNOCK_KNOCK_VOICE_GOLDEN_V2.json"
generated_root="$dataset_root/voice-golden-v2-generated"
manifest_path="$generated_root/audio-manifest.jsonl"
[[ -s "$dataset_path" && -s "$manifest_path" ]] || fail "dataset JSON or manifest is missing"

example_count=$(jq '.examples | length' "$dataset_path")
row_count=$(wc -l <"$manifest_path" | tr -d ' ')
unique_path_count=$(jq -r '.relative_path' "$manifest_path" | sort -u | wc -l | tr -d ' ')
unique_hash_count=$(jq -r '.sha256' "$manifest_path" | sort -u | wc -l | tr -d ' ')
[[ $example_count -eq 48 && $row_count -eq 144 \
  && $unique_path_count -eq 144 && $unique_hash_count -eq 144 ]] \
  || fail "dataset counts or unique-audio gate failed"

while IFS=$'\t' read -r relative_path expected_hash; do
  [[ "$relative_path" == audio/* && "$relative_path" != *..* && "$relative_path" != /* ]] \
    || fail "manifest contains an unsafe audio path"
  audio_path="$generated_root/$relative_path"
  [[ -f "$audio_path" && ! -L "$audio_path" && -s "$audio_path" ]] \
    || fail "manifest audio is missing or unsafe: $relative_path"
  actual_hash=$(shasum -a 256 "$audio_path" | awk '{print $1}')
  [[ "$actual_hash" == "$expected_hash" ]] || fail "audio hash mismatch: $relative_path"
done < <(jq -r '[.relative_path, .sha256] | @tsv' "$manifest_path")

temporary_directory=$(mktemp -d "${temporary_root%/}/knock-knock-voice-audio-uat.XXXXXX")
payload="$temporary_directory/KnockKnockVoiceAudioUAT"
mkdir -p "$payload/voice-golden-v2-generated/audio" "$payload/voice-golden-v2-generated/results"
cp "$dataset_path" "$payload/KNOCK_KNOCK_VOICE_GOLDEN_V2.json"
cp "$manifest_path" "$payload/voice-golden-v2-generated/audio-manifest.jsonl"
cp -R "$generated_root/audio/." "$payload/voice-golden-v2-generated/audio/"

apps_json="$temporary_directory/apps.json"
xcrun devicectl device info apps \
  --device "$device_id" \
  --bundle-id "$BUNDLE_ID" \
  --json-output "$apps_json" \
  --quiet >/dev/null || fail "the device or installed app could not be queried"
grep -q "$BUNDLE_ID" "$apps_json" || fail "$BUNDLE_ID is not installed on the selected device"

copy_json="$temporary_directory/copy.json"
xcrun devicectl device copy to \
  --device "$device_id" \
  --source "$payload" \
  --destination "$DEVICE_TARGET_DIRECTORY" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --remove-existing-content false \
  --json-output "$copy_json" \
  --quiet >/dev/null || fail "the validated audio UAT payload could not be staged"

printf 'Staged 144 validated WAV files at %s for %s.\n' "$DEVICE_TARGET_DIRECTORY" "$BUNDLE_ID"
printf 'Raw audio remains in the app test container and is never uploaded.\n'
