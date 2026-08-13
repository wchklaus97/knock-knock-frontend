#!/usr/bin/env bash
set -euo pipefail

readonly MANIFEST_NAME="manifest.jsonl"
readonly MINIMUM_ROW_COUNT=36
readonly MINIMUM_ROWS_PER_LOCALE=12
readonly MINIMUM_SPEAKERS_PER_LOCALE=3
readonly MINIMUM_ROWS_PER_SPEAKER=4

validation_temp_directory=""
self_test_temp_directory=""
_self_test_snapshot_callback=""

usage() {
  printf '%s\n' \
    'Usage: scripts/validate-human-voice-corpus.sh --corpus-dir ABSOLUTE_DIRECTORY --provenance-consent-reviewed' \
    '       scripts/validate-human-voice-corpus.sh ABSOLUTE_DIRECTORY --provenance-consent-reviewed' \
    '       scripts/validate-human-voice-corpus.sh --self-test' \
    '' \
    'Validate an external human-voice corpus without copying or uploading audio.' \
    "The corpus directory must contain ${MANIFEST_NAME}; audio paths are relative to it." \
    'The directory and all of its contents must be non-symlink paths outside this' \
    'Git worktree.' \
    '' \
    '--provenance-consent-reviewed is an operator attestation that the manual' \
    'human-origin, consent, and privacy review documented in the UAT guide is complete.' \
    'Audio metadata validation cannot prove that a recording is human or exclude TTS/replay.'
}

fail() {
  printf 'human voice corpus validation failed: %s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'human voice corpus validation failed: %s\n\n' "$1" >&2
  usage >&2
  exit 64
}

cleanup_validation_temp() {
  if [[ -n "$validation_temp_directory" && -d "$validation_temp_directory" && ! -L "$validation_temp_directory" ]]; then
    rm -rf -- "$validation_temp_directory"
  fi
  validation_temp_directory=""
}

cleanup_self_test_temp() {
  if [[ -n "$self_test_temp_directory" && -d "$self_test_temp_directory" && ! -L "$self_test_temp_directory" ]]; then
    rm -rf -- "$self_test_temp_directory"
  fi
  self_test_temp_directory=""
}

path_has_symlink_component() {
  local absolute_path=$1
  local current_path=""
  local remainder=${absolute_path#/}
  local component

  while [[ -n "$remainder" ]]; do
    if [[ "$remainder" == */* ]]; then
      component=${remainder%%/*}
      remainder=${remainder#*/}
    else
      component=$remainder
      remainder=""
    fi
    [[ -n "$component" ]] || continue
    current_path="${current_path}/${component}"
    [[ ! -L "$current_path" ]] || return 0
  done
  return 1
}

create_private_validation_temp() {
  local worktree_root=$1
  local temp_parent=${TMPDIR:-/tmp}

  if [[ "$temp_parent" != /* || ! -d "$temp_parent" ]]; then
    temp_parent=/tmp
  fi
  temp_parent=$(cd "$temp_parent" && pwd -P) \
    || fail "could not resolve the private temporary-file parent"
  case "$temp_parent" in
    "$worktree_root"|"$worktree_root"/*)
      if [[ -d /private/tmp ]]; then
        temp_parent=/private/tmp
      else
        temp_parent=/tmp
      fi
      temp_parent=$(cd "$temp_parent" && pwd -P) \
        || fail "could not resolve a temporary-file parent outside the worktree"
      ;;
  esac

  validation_temp_directory=$(mktemp -d "$temp_parent/knock-human-corpus-validator.XXXXXX") \
    || fail "could not create a private temporary directory"
  chmod 700 "$validation_temp_directory" \
    || fail "could not protect the private temporary directory"
}

snapshot_manifest() {
  local source_path=$1
  local snapshot_path=$2

  python3 - "$source_path" "$snapshot_path" <<'PY'
import hashlib
import os
import stat
import sys

source_path, snapshot_path = sys.argv[1:]

def abort(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

if not hasattr(os, "O_NOFOLLOW"):
    abort("this platform cannot open the manifest without following symlinks")

flags = os.O_RDONLY | os.O_NOFOLLOW
if hasattr(os, "O_NONBLOCK"):
    flags |= os.O_NONBLOCK
if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC

try:
    source_fd = os.open(source_path, flags)
except OSError:
    abort("manifest could not be opened as a non-symlink file")

try:
    before = os.fstat(source_fd)
    if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
        abort("manifest must be a non-empty regular file")
    try:
        path_before = os.lstat(source_path)
    except OSError:
        abort("manifest path changed before it could be snapshotted")
    if stat.S_ISLNK(path_before.st_mode) or (path_before.st_dev, path_before.st_ino) != (before.st_dev, before.st_ino):
        abort("manifest path changed or became a symlink before it could be snapshotted")

    destination_fd = os.open(
        snapshot_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        os.fsync(destination_fd)
    finally:
        os.close(destination_fd)

    after = os.fstat(source_fd)
    try:
        path_after = os.lstat(source_path)
    except OSError:
        abort("manifest path changed while it was being snapshotted")

    signature_before = (
        before.st_dev, before.st_ino, before.st_size,
        before.st_mtime_ns, before.st_ctime_ns,
    )
    signature_after = (
        after.st_dev, after.st_ino, after.st_size,
        after.st_mtime_ns, after.st_ctime_ns,
    )
    if signature_after != signature_before:
        abort("manifest changed while it was being snapshotted")
    if stat.S_ISLNK(path_after.st_mode) or (path_after.st_dev, path_after.st_ino) != (before.st_dev, before.st_ino):
        abort("manifest path changed or became a symlink while it was being snapshotted")

    print("\t".join(str(value) for value in (*signature_before, digest.hexdigest())))
finally:
    os.close(source_fd)
PY
}

verify_manifest_unchanged() {
  local source_path=$1
  local expected_device=$2
  local expected_inode=$3
  local expected_size=$4
  local expected_mtime_ns=$5
  local expected_ctime_ns=$6
  local expected_hash=$7

  python3 - \
    "$source_path" "$expected_device" "$expected_inode" "$expected_size" \
    "$expected_mtime_ns" "$expected_ctime_ns" "$expected_hash" <<'PY'
import hashlib
import os
import stat
import sys

source_path = sys.argv[1]
expected_signature = tuple(int(value) for value in sys.argv[2:7])
expected_hash = sys.argv[7]

def abort(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

if not hasattr(os, "O_NOFOLLOW"):
    abort("this platform cannot re-open the manifest without following symlinks")

flags = os.O_RDONLY | os.O_NOFOLLOW
if hasattr(os, "O_NONBLOCK"):
    flags |= os.O_NONBLOCK
if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC

try:
    source_fd = os.open(source_path, flags)
except OSError:
    abort("manifest changed after the immutable snapshot was created")

try:
    before = os.fstat(source_fd)
    signature = (
        before.st_dev, before.st_ino, before.st_size,
        before.st_mtime_ns, before.st_ctime_ns,
    )
    if not stat.S_ISREG(before.st_mode) or signature != expected_signature:
        abort("manifest changed after the immutable snapshot was created")

    digest = hashlib.sha256()
    while True:
        chunk = os.read(source_fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(source_fd)
    if (
        after.st_dev, after.st_ino, after.st_size,
        after.st_mtime_ns, after.st_ctime_ns,
    ) != expected_signature:
        abort("manifest changed during the final integrity check")
    try:
        path_after = os.lstat(source_path)
    except OSError:
        abort("manifest path changed during the final integrity check")
    if stat.S_ISLNK(path_after.st_mode) or (path_after.st_dev, path_after.st_ino) != (before.st_dev, before.st_ino):
        abort("manifest path changed during the final integrity check")
    if digest.hexdigest() != expected_hash:
        abort("manifest bytes changed after the immutable snapshot was created")
finally:
    os.close(source_fd)
PY
}

validate_rfc3339_timestamps() {
  local manifest_snapshot=$1

  python3 - "$manifest_snapshot" <<'PY'
import calendar
import json
import re
import sys

manifest_path = sys.argv[1]
pattern = re.compile(
    r"^(?P<year>[0-9]{4})-(?P<month>[0-9]{2})-(?P<day>[0-9]{2})"
    r"T(?P<hour>[0-9]{2}):(?P<minute>[0-9]{2}):(?P<second>[0-9]{2})"
    r"(?:\.(?P<fraction>[0-9]{1,9}))?"
    r"(?P<zone>Z|(?P<sign>[+-])(?P<offset_hour>[0-9]{2}):(?P<offset_minute>[0-9]{2}))$"
)

with open(manifest_path, "r", encoding="utf-8") as manifest:
    for line_number, line in enumerate(manifest, 1):
        row = json.loads(line)
        if row.get("expected_intent") != "create_reminder":
            continue
        value = row["expected_args"]["due_at"]
        match = pattern.fullmatch(value)
        if not match:
            print(f"manifest line {line_number} has an invalid RFC 3339 timestamp", file=sys.stderr)
            raise SystemExit(1)
        parts = {name: int(match.group(name)) for name in ("year", "month", "day", "hour", "minute", "second")}
        valid = (
            parts["year"] >= 1
            and 1 <= parts["month"] <= 12
            and 0 <= parts["hour"] <= 23
            and 0 <= parts["minute"] <= 59
            and 0 <= parts["second"] <= 59
        )
        if valid:
            last_day = calendar.monthrange(parts["year"], parts["month"])[1]
            valid = 1 <= parts["day"] <= last_day
        if match.group("zone") != "Z":
            valid = valid and int(match.group("offset_hour")) <= 23 and int(match.group("offset_minute")) <= 59
        if not valid:
            print(f"manifest line {line_number} has a semantically invalid RFC 3339 timestamp", file=sys.stderr)
            raise SystemExit(1)
PY
}

probe_and_hash_audio() {
  local audio_path=$1
  local relative_path=$2
  local expected_hash=$3
  local probe_kind=$4
  local probe_command=$5

  python3 - "$audio_path" "$relative_path" "$expected_hash" "$probe_kind" "$probe_command" <<'PY'
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

audio_path, relative_path, expected_hash, probe_kind, probe_command = sys.argv[1:]
extension = relative_path.rsplit(".", 1)[-1]

def abort(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

if not hasattr(os, "O_NOFOLLOW"):
    abort("platform cannot open audio without following symlinks")

flags = os.O_RDONLY | os.O_NOFOLLOW
if hasattr(os, "O_NONBLOCK"):
    flags |= os.O_NONBLOCK
try:
    audio_fd = os.open(audio_path, flags)
except OSError:
    abort("audio could not be opened as a non-symlink file")

try:
    before = os.fstat(audio_fd)
    if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
        abort("audio is missing, empty, or not a regular file")
    try:
        path_before = os.lstat(audio_path)
    except OSError:
        abort("audio path changed before metadata inspection")
    if stat.S_ISLNK(path_before.st_mode) or (path_before.st_dev, path_before.st_ino) != (before.st_dev, before.st_ino):
        abort("audio path changed or became a symlink before metadata inspection")

    descriptor_path = f"/dev/fd/{audio_fd}"
    if probe_kind == "ffprobe":
        command = [
            probe_command, "-v", "error", "-count_packets",
            "-show_entries",
            "stream=codec_type,sample_rate,channels,duration,nb_read_packets:format=format_name,duration",
            "-of", "json", descriptor_path,
        ]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(audio_fd,), check=False)
        if result.returncode != 0:
            abort("ffprobe could not parse the file as audio")
        try:
            metadata = json.loads(result.stdout)
        except (UnicodeDecodeError, json.JSONDecodeError):
            abort("ffprobe returned invalid metadata")
        streams = metadata.get("streams") or []
        if not streams or any(stream.get("codec_type") != "audio" for stream in streams):
            abort("file must contain audio streams only")
        for stream in streams:
            try:
                sample_rate = int(stream.get("sample_rate", 0))
                channels = int(stream.get("channels", 0))
                packets = int(stream.get("nb_read_packets", 0))
            except (TypeError, ValueError):
                abort("audio stream metadata is incomplete")
            if sample_rate <= 0 or channels <= 0 or packets <= 0:
                abort("audio stream has no decodable packets, channels, or sample rate")
        format_metadata = metadata.get("format") or {}
        try:
            duration = float(format_metadata.get("duration", 0))
        except (TypeError, ValueError):
            abort("audio duration is missing")
        if duration <= 0:
            abort("audio duration must be positive")
        format_names = set(str(format_metadata.get("format_name", "")).split(","))
        if extension == "wav" and "wav" not in format_names:
            abort(".wav extension does not contain a WAVE container")
        if extension == "m4a" and "m4a" not in format_names:
            abort(".m4a extension does not contain an M4A container")
    else:
        command = [probe_command, "-b", descriptor_path]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(audio_fd,), check=False)
        if result.returncode != 0:
            abort("afinfo could not parse the file as audio")
        try:
            output = result.stdout.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            abort("afinfo returned invalid metadata")
        tracks = re.search(r"Num Tracks:\s*([0-9]+)", output)
        stream = re.search(r"([0-9]+(?:\.[0-9]+)?) sec, format:\s*([0-9]+) ch,\s*([0-9]+(?:\.[0-9]+)?) Hz", output)
        if not tracks or int(tracks.group(1)) <= 0 or not stream:
            abort("afinfo found no usable audio track")
        if float(stream.group(1)) <= 0 or int(stream.group(2)) <= 0 or float(stream.group(3)) <= 0:
            abort("audio duration, channels, and sample rate must be positive")
        if extension == "wav" and not re.search(r",\s*WAVE,", output):
            abort(".wav extension does not contain a WAVE container")
        if extension == "m4a" and not re.search(r",\s*m4af,", output):
            abort(".m4a extension does not contain an M4A container")

    os.lseek(audio_fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(audio_fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(audio_fd)
    signature_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
    signature_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    if signature_after != signature_before:
        abort("audio changed during metadata or hash validation")
    try:
        path_after = os.lstat(audio_path)
    except OSError:
        abort("audio path changed during metadata or hash validation")
    if stat.S_ISLNK(path_after.st_mode) or (path_after.st_dev, path_after.st_ino) != (before.st_dev, before.st_ino):
        abort("audio path changed or became a symlink during validation")
    if digest.hexdigest() != expected_hash:
        abort("SHA-256 mismatch")
finally:
    os.close(audio_fd)
PY
}

write_audio_inventory() {
  local corpus_root=$1
  local inventory_path=$2
  local symlink_inventory=$3
  local entry
  local relative_path

  : >"$inventory_path"
  if ! find -P "$corpus_root" -mindepth 1 -type l -print0 >"$symlink_inventory"; then
    fail "could not inspect the corpus for symlinks"
  fi
  if IFS= read -r -d '' entry <"$symlink_inventory"; then
    fail "the corpus must not contain symlinks"
  fi
  if ! find -P "$corpus_root" -mindepth 1 \( -name '*.wav' -o -name '*.m4a' \) -print0 >"$inventory_path.nul"; then
    fail "could not inventory corpus audio"
  fi
  while IFS= read -r -d '' entry; do
    [[ -f "$entry" && ! -L "$entry" ]] \
      || fail "every lowercase .wav/.m4a entry must be a non-symlink regular file"
    relative_path=${entry#"$corpus_root"/}
    [[ "$relative_path" != "$entry" ]] \
      || fail "audio inventory escaped the corpus root"
    [[ "$relative_path" =~ ^([A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\.(wav|m4a)$ ]] \
      || fail "every lowercase .wav/.m4a file must use a safe manifest-compatible path"
    printf '%s\n' "$relative_path" >>"$inventory_path"
  done <"$inventory_path.nul"
}

validate_corpus() {
  local corpus_input=$1
  local provenance_reviewed=$2
  local script_directory
  local worktree_root
  local corpus_root
  local manifest_path
  local manifest_snapshot
  local snapshot_result
  local snapshot_device
  local snapshot_inode
  local snapshot_size
  local snapshot_mtime_ns
  local snapshot_ctime_ns
  local snapshot_hash
  local audio_probe_kind
  local audio_probe_command
  local command_name
  local line_number=0
  local manifest_line
  local timestamp_error
  local stats
  local unique_sample_count
  local unique_path_count
  local unique_hash_count
  local locale
  local locale_rows
  local locale_speakers
  local underfilled_speakers
  local has_coverage
  local coverage_name
  local manifest_paths
  local sorted_manifest_paths
  local audio_inventory
  local sorted_audio_inventory
  local final_audio_inventory
  local sorted_final_audio_inventory
  local symlink_inventory
  local sample_id
  local relative_path
  local expected_hash
  local audio_path
  local audio_error
  local validated_audio_count=0
  local clarification_rows
  local final_manifest_error
  local -a locales
  local -a locale_report
  local -a required_intents

  [[ "$provenance_reviewed" == "true" ]] \
    || fail "manual provenance, consent, and privacy review is required; pass --provenance-consent-reviewed only after completing it"
  [[ -n "$corpus_input" ]] || usage_error "a corpus directory is required"
  [[ "$corpus_input" == /* ]] || fail "the corpus directory must be absolute"

  while [[ "$corpus_input" != "/" && "$corpus_input" == */ ]]; do
    corpus_input=${corpus_input%/}
  done
  case "${corpus_input}/" in
    *//*|*/./*|*/../*)
      fail "the corpus directory must not contain empty, . or .. path components"
      ;;
  esac
  [[ "$corpus_input" != "/" && -d "$corpus_input" && ! -L "$corpus_input" ]] \
    || fail "the corpus directory must be an existing non-symlink directory other than /"
  if path_has_symlink_component "$corpus_input"; then
    fail "the corpus directory must not traverse a symlink"
  fi

  for command_name in git jq python3 find sort cmp mktemp chmod rm; do
    command -v "$command_name" >/dev/null || fail "$command_name is required"
  done
  if command -v ffprobe >/dev/null; then
    audio_probe_kind=ffprobe
    audio_probe_command=$(command -v ffprobe)
  elif command -v afinfo >/dev/null; then
    audio_probe_kind=afinfo
    audio_probe_command=$(command -v afinfo)
  else
    fail "ffprobe or afinfo is required for audio metadata validation"
  fi

  script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  worktree_root=$(git -C "$script_directory" rev-parse --show-toplevel 2>/dev/null) \
    || fail "could not resolve this Git worktree"
  worktree_root=$(cd "$worktree_root" && pwd -P)
  corpus_root=$(cd "$corpus_input" && pwd -P)
  case "$corpus_root" in
    "$worktree_root"|"$worktree_root"/*)
      fail "the corpus directory must be outside this Git worktree"
      ;;
  esac

  manifest_path="$corpus_root/$MANIFEST_NAME"
  [[ -f "$manifest_path" && ! -L "$manifest_path" && -s "$manifest_path" ]] \
    || fail "$MANIFEST_NAME must be a non-empty, non-symlink regular file"
  if path_has_symlink_component "$manifest_path"; then
    fail "$MANIFEST_NAME must not traverse a symlink"
  fi

  umask 077
  create_private_validation_temp "$worktree_root"
  trap cleanup_validation_temp EXIT
  trap 'exit 130' HUP INT TERM
  manifest_snapshot="$validation_temp_directory/$MANIFEST_NAME"
  if ! snapshot_result=$(snapshot_manifest "$manifest_path" "$manifest_snapshot" 2>&1); then
    fail "could not create immutable manifest snapshot: $snapshot_result"
  fi
  IFS=$'\t' read -r snapshot_device snapshot_inode snapshot_size snapshot_mtime_ns snapshot_ctime_ns snapshot_hash <<<"$snapshot_result"
  [[ -n "$snapshot_hash" ]] || fail "immutable manifest snapshot did not return an integrity signature"

  if [[ -n "$_self_test_snapshot_callback" ]]; then
    "$_self_test_snapshot_callback" "$manifest_path"
  fi

  while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    line_number=$((line_number + 1))
    [[ "$manifest_line" =~ [^[:space:]] ]] || fail "blank line at manifest line $line_number"

    if ! jq -e -s '
      def nonblank($maximum):
        type == "string" and length > 0 and length <= $maximum and test("\\S");
      def exact_object($expected_keys):
        type == "object" and ((keys | sort) == ($expected_keys | sort));
      def rfc3339_shape:
        type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$");

      [
        "sample_id", "locale", "speaker_id", "capture_type", "relative_path",
        "sha256", "expected_transcript", "expected_outcome", "expected_intent",
        "expected_args", "risk_level", "needs_confirmation", "ambiguity_kind"
      ] as $required
      | ($required + ["schema_version"]) as $allowed
      | length == 1
        and (
          .[0]
          | type == "object"
          and (($required - keys) | length == 0)
          and ((keys - $allowed) | length == 0)
          and ((has("schema_version") | not) or .schema_version == 1)
          and (.sample_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
          and (.locale == "en-HK" or .locale == "zh-Hans-CN" or .locale == "yue-Hant-HK")
          and (.speaker_id | type == "string" and test("^spk_[0-9a-f]{12,64}$"))
          and .capture_type == "human"
          and (
            .relative_path
            | type == "string"
              and length <= 512
              and test("^(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\\.(?:wav|m4a)$")
          )
          and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          and (.expected_transcript | nonblank(1000))
          and (
            (
              .expected_outcome == "command"
              and .ambiguity_kind == "none"
              and (
                (
                  .expected_intent == "search_history"
                  and ((.expected_args | exact_object(["q"])))
                  and (.expected_args.q | nonblank(200))
                  and .risk_level == "low"
                  and .needs_confirmation == false
                )
                or (
                  .expected_intent == "create_reminder"
                  and ((.expected_args | exact_object(["due_at", "title"])))
                  and (.expected_args.title | nonblank(200))
                  and (.expected_args.due_at | length <= 64 and rfc3339_shape)
                  and .risk_level == "low"
                  and .needs_confirmation == false
                )
                or (
                  .expected_intent == "create_draft"
                  and (
                    (.expected_args | exact_object(["body"]))
                    or (.expected_args | exact_object(["body", "title"]))
                  )
                  and (.expected_args.body | nonblank(4000))
                  and (
                    (.expected_args | has("title") | not)
                    or (.expected_args.title | nonblank(200))
                  )
                  and .risk_level == "low"
                  and .needs_confirmation == false
                )
                or (
                  .expected_intent == "send_message"
                  and ((.expected_args | exact_object(["body", "recipient"])))
                  and (.expected_args.recipient | nonblank(320))
                  and (.expected_args.body | nonblank(4000))
                  and .risk_level == "high"
                  and .needs_confirmation == true
                )
              )
            )
            or (
              .expected_outcome == "clarification"
              and .expected_intent == null
              and (.expected_args | type == "object" and length == 0)
              and .risk_level == null
              and .needs_confirmation == false
              and (
                .ambiguity_kind == "person"
                or .ambiguity_kind == "time"
                or .ambiguity_kind == "amount"
              )
            )
          )
        )
    ' >/dev/null 2>&1 <<<"$manifest_line"; then
      fail "manifest line $line_number violates the row schema or command semantics"
    fi
  done <"$manifest_snapshot"

  ((line_number >= MINIMUM_ROW_COUNT)) \
    || fail "manifest has $line_number rows; at least $MINIMUM_ROW_COUNT are required"

  if ! timestamp_error=$(validate_rfc3339_timestamps "$manifest_snapshot" 2>&1); then
    fail "${timestamp_error:-could not validate RFC 3339 timestamps}"
  fi

  stats=$(jq -c -s '
    . as $rows
    | ["en-HK", "zh-Hans-CN", "yue-Hant-HK"] as $locales
    | {
        rows: ($rows | length),
        unique_sample_ids: ($rows | map(.sample_id) | unique | length),
        unique_paths: ($rows | map(.relative_path) | unique | length),
        unique_hashes: ($rows | map(.sha256) | unique | length),
        clarification_rows: ($rows | map(select(.expected_outcome == "clarification")) | length),
        locales: [
          $locales[] as $locale
          | ([$rows[] | select(.locale == $locale)] | sort_by(.speaker_id) | group_by(.speaker_id)) as $speaker_groups
          | {
              locale: $locale,
              rows: ([$rows[] | select(.locale == $locale)] | length),
              speakers: ($speaker_groups | length),
              underfilled_speakers: ([$speaker_groups[] | select(length < 4)] | length),
              search_history: any($rows[]; .locale == $locale and .expected_outcome == "command" and .expected_intent == "search_history"),
              create_reminder: any($rows[]; .locale == $locale and .expected_outcome == "command" and .expected_intent == "create_reminder"),
              create_draft: any($rows[]; .locale == $locale and .expected_outcome == "command" and .expected_intent == "create_draft"),
              send_message: any($rows[]; .locale == $locale and .expected_outcome == "command" and .expected_intent == "send_message"),
              person: any($rows[]; .locale == $locale and .expected_outcome == "clarification" and .ambiguity_kind == "person"),
              time: any($rows[]; .locale == $locale and .expected_outcome == "clarification" and .ambiguity_kind == "time"),
              amount: any($rows[]; .locale == $locale and .expected_outcome == "clarification" and .ambiguity_kind == "amount")
            }
        ]
      }
  ' "$manifest_snapshot") || fail "could not summarize the immutable manifest snapshot"

  unique_sample_count=$(jq -r '.unique_sample_ids' <<<"$stats")
  unique_path_count=$(jq -r '.unique_paths' <<<"$stats")
  unique_hash_count=$(jq -r '.unique_hashes' <<<"$stats")
  [[ "$unique_sample_count" -eq "$line_number" ]] || fail "sample_id values must be unique"
  [[ "$unique_path_count" -eq "$line_number" ]] || fail "relative_path values must be unique"
  [[ "$unique_hash_count" -eq "$line_number" ]] || fail "sha256 content hashes must be unique"

  locales=("en-HK" "zh-Hans-CN" "yue-Hant-HK")
  required_intents=("search_history" "create_reminder" "create_draft" "send_message")
  locale_report=()
  for locale in "${locales[@]}"; do
    locale_rows=$(jq -r --arg locale "$locale" '.locales[] | select(.locale == $locale) | .rows' <<<"$stats")
    locale_speakers=$(jq -r --arg locale "$locale" '.locales[] | select(.locale == $locale) | .speakers' <<<"$stats")
    underfilled_speakers=$(jq -r --arg locale "$locale" '.locales[] | select(.locale == $locale) | .underfilled_speakers' <<<"$stats")
    ((locale_rows >= MINIMUM_ROWS_PER_LOCALE)) \
      || fail "$locale has $locale_rows rows; at least $MINIMUM_ROWS_PER_LOCALE are required"
    ((locale_speakers >= MINIMUM_SPEAKERS_PER_LOCALE)) \
      || fail "$locale has $locale_speakers opaque speakers; at least $MINIMUM_SPEAKERS_PER_LOCALE are required"
    ((underfilled_speakers == 0)) \
      || fail "$locale has $underfilled_speakers opaque speakers with fewer than $MINIMUM_ROWS_PER_SPEAKER recordings"

    for coverage_name in "${required_intents[@]}"; do
      has_coverage=$(jq -r --arg locale "$locale" --arg coverage "$coverage_name" '.locales[] | select(.locale == $locale) | .[$coverage]' <<<"$stats")
      [[ "$has_coverage" == "true" ]] \
        || fail "$locale is missing command coverage for $coverage_name"
    done
    for coverage_name in person time amount; do
      has_coverage=$(jq -r --arg locale "$locale" --arg coverage "$coverage_name" '.locales[] | select(.locale == $locale) | .[$coverage]' <<<"$stats")
      [[ "$has_coverage" == "true" ]] \
        || fail "$locale is missing an expected clarification for ambiguous $coverage_name"
    done
    locale_report+=("$locale=$locale_rows/${locale_speakers}spk")
  done

  manifest_paths="$validation_temp_directory/manifest-paths"
  sorted_manifest_paths="$validation_temp_directory/manifest-paths.sorted"
  audio_inventory="$validation_temp_directory/audio-inventory"
  sorted_audio_inventory="$validation_temp_directory/audio-inventory.sorted"
  final_audio_inventory="$validation_temp_directory/audio-inventory.final"
  sorted_final_audio_inventory="$validation_temp_directory/audio-inventory.final.sorted"
  symlink_inventory="$validation_temp_directory/symlinks"
  jq -r '.relative_path' "$manifest_snapshot" >"$manifest_paths" \
    || fail "could not enumerate manifest audio paths"
  LC_ALL=C sort "$manifest_paths" >"$sorted_manifest_paths" \
    || fail "could not sort manifest audio paths"
  write_audio_inventory "$corpus_root" "$audio_inventory" "$symlink_inventory"
  LC_ALL=C sort "$audio_inventory" >"$sorted_audio_inventory" \
    || fail "could not sort corpus audio inventory"
  cmp -s "$sorted_manifest_paths" "$sorted_audio_inventory" \
    || fail "audio inventory does not exactly match manifest paths; missing or extra lowercase .wav/.m4a files are forbidden"

  if ! jq -r '[.sample_id, .relative_path, .sha256] | @tsv' "$manifest_snapshot" >"$validation_temp_directory/audio-rows.tsv"; then
    fail "could not enumerate immutable manifest audio rows"
  fi
  while IFS=$'\t' read -r sample_id relative_path expected_hash; do
    audio_path="$corpus_root/$relative_path"
    if path_has_symlink_component "$audio_path"; then
      fail "$sample_id references an audio path that traverses a symlink"
    fi
    if ! audio_error=$(probe_and_hash_audio "$audio_path" "$relative_path" "$expected_hash" "$audio_probe_kind" "$audio_probe_command" 2>&1); then
      fail "$sample_id failed audio metadata or hash validation: ${audio_error:-unknown audio validation error}"
    fi
    if path_has_symlink_component "$audio_path"; then
      fail "$sample_id audio path became symlinked during validation"
    fi
    validated_audio_count=$((validated_audio_count + 1))
  done <"$validation_temp_directory/audio-rows.tsv"

  [[ "$validated_audio_count" -eq "$line_number" ]] \
    || fail "validated $validated_audio_count audio files for $line_number immutable manifest rows"

  write_audio_inventory "$corpus_root" "$final_audio_inventory" "$symlink_inventory"
  LC_ALL=C sort "$final_audio_inventory" >"$sorted_final_audio_inventory" \
    || fail "could not sort final corpus audio inventory"
  cmp -s "$sorted_manifest_paths" "$sorted_final_audio_inventory" \
    || fail "audio inventory changed during validation"

  if ! final_manifest_error=$(verify_manifest_unchanged \
    "$manifest_path" "$snapshot_device" "$snapshot_inode" "$snapshot_size" \
    "$snapshot_mtime_ns" "$snapshot_ctime_ns" "$snapshot_hash" 2>&1); then
    fail "${final_manifest_error:-manifest changed after the immutable snapshot was created}"
  fi

  clarification_rows=$(jq -r '.clarification_rows' <<<"$stats")
  printf 'Human voice corpus structurally valid: rows=%s audio=%s %s clarifications=%s manual_provenance_review=attested\n' \
    "$line_number" \
    "$validated_audio_count" \
    "${locale_report[*]}" \
    "$clarification_rows"
}

make_self_test_fixture() {
  local corpus_root=$1
  local -a locales=("en-HK" "zh-Hans-CN" "yue-Hant-HK")
  local locale
  local locale_index=0
  local row_in_locale
  local global_row=0
  local speaker_number
  local speaker_id
  local sample_id
  local relative_path
  local audio_path
  local audio_hash
  local outcome
  local intent_json
  local args_json
  local risk_json
  local confirmation_json
  local ambiguity_kind
  local transcript

  mkdir -p "$corpus_root/audio"
  : >"$corpus_root/$MANIFEST_NAME"
  for locale in "${locales[@]}"; do
    locale_index=$((locale_index + 1))
    mkdir -p "$corpus_root/audio/$locale"
    for row_in_locale in $(seq 1 12); do
      global_row=$((global_row + 1))
      speaker_number=$(((row_in_locale - 1) / 4 + 1))
      speaker_id=$(printf 'spk_%012x' $((locale_index * 16 + speaker_number)))
      sample_id=$(printf 'hvc_%03d' "$global_row")
      relative_path="audio/$locale/$sample_id.wav"
      audio_path="$corpus_root/$relative_path"
      python3 - "$audio_path" "$global_row" <<'PY'
import math
import struct
import sys
import wave

path, index = sys.argv[1], int(sys.argv[2])
sample_rate = 16000
frame_count = 1600
frequency = 240 + index * 7
frames = b"".join(
    struct.pack("<h", int(8000 * math.sin(2 * math.pi * frequency * frame / sample_rate)))
    for frame in range(frame_count)
)
with wave.open(path, "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(sample_rate)
    output.writeframes(frames)
PY
      audio_hash=$(shasum -a 256 "$audio_path" | awk '{print $1}')

      outcome="command"
      risk_json='"low"'
      confirmation_json=false
      ambiguity_kind=none
      transcript="Fictional test utterance $global_row"
      case "$row_in_locale" in
        1|8|12)
          intent_json='"search_history"'
          args_json='{"q":"fictional project"}'
          ;;
        2|9)
          intent_json='"create_reminder"'
          args_json='{"title":"fictional reminder","due_at":"2026-09-01T10:30:00+08:00"}'
          ;;
        3|10)
          intent_json='"create_draft"'
          args_json='{"title":"fictional note","body":"fictional body"}'
          ;;
        4|11)
          intent_json='"send_message"'
          args_json='{"recipient":"Fictional Recipient","body":"fictional message"}'
          risk_json='"high"'
          confirmation_json=true
          ;;
        5)
          outcome=clarification
          intent_json=null
          args_json='{}'
          risk_json=null
          ambiguity_kind=person
          ;;
        6)
          outcome=clarification
          intent_json=null
          args_json='{}'
          risk_json=null
          ambiguity_kind="time"
          ;;
        7)
          outcome=clarification
          intent_json=null
          args_json='{}'
          risk_json=null
          ambiguity_kind=amount
          ;;
      esac

      jq -nc \
        --arg sample_id "$sample_id" \
        --arg locale "$locale" \
        --arg speaker_id "$speaker_id" \
        --arg relative_path "$relative_path" \
        --arg sha256 "$audio_hash" \
        --arg transcript "$transcript" \
        --arg outcome "$outcome" \
        --argjson intent "$intent_json" \
        --argjson args "$args_json" \
        --argjson risk "$risk_json" \
        --argjson confirmation "$confirmation_json" \
        --arg ambiguity "$ambiguity_kind" \
        '{schema_version:1,sample_id:$sample_id,locale:$locale,speaker_id:$speaker_id,capture_type:"human",relative_path:$relative_path,sha256:$sha256,expected_transcript:$transcript,expected_outcome:$outcome,expected_intent:$intent,expected_args:$args,risk_level:$risk,needs_confirmation:$confirmation,ambiguity_kind:$ambiguity}' \
        >>"$corpus_root/$MANIFEST_NAME"
    done
  done
}

clone_self_test_fixture() {
  local source=$1
  local destination=$2
  mkdir -p "$destination"
  cp -R "$source/." "$destination/"
}

self_test_replace_manifest_with_duplicates() {
  local manifest_path=$1
  local replacement_path="$manifest_path.replacement"
  sed -n '1,35p' "$manifest_path" >"$replacement_path"
  sed -n '1p' "$manifest_path" >>"$replacement_path"
  mv -f "$replacement_path" "$manifest_path"
}

expect_self_test_pass() {
  local name=$1
  local corpus_root=$2
  local log_path="$self_test_temp_directory/$name.log"
  if (validation_temp_directory=""; _self_test_snapshot_callback=""; validate_corpus "$corpus_root" true) >"$log_path" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    sed -n '1,20p' "$log_path" >&2
    fail "self-test unexpectedly failed: $name"
  fi
}

expect_self_test_fail() {
  local name=$1
  local corpus_root=$2
  local expected_message=$3
  local callback=${4:-}
  local log_path="$self_test_temp_directory/$name.log"
  if (validation_temp_directory=""; _self_test_snapshot_callback="$callback"; validate_corpus "$corpus_root" true) >"$log_path" 2>&1; then
    fail "self-test unexpectedly passed: $name"
  fi
  if [[ $(<"$log_path") != *"$expected_message"* ]]; then
    sed -n '1,20p' "$log_path" >&2
    fail "self-test failed for the wrong reason: $name"
  fi
  printf 'PASS %s (rejected)\n' "$name"
}

run_self_tests() {
  local temp_parent=/tmp
  local base_fixture
  local case_fixture
  local manifest_path
  local replacement_path
  local fake_path
  local fake_hash

  for command_name in jq python3 shasum awk sed mv cp seq; do
    command -v "$command_name" >/dev/null || fail "$command_name is required for --self-test"
  done
  if [[ -d /private/tmp ]]; then
    temp_parent=/private/tmp
  fi
  temp_parent=$(cd "$temp_parent" && pwd -P)
  umask 077
  self_test_temp_directory=$(mktemp -d "$temp_parent/knock-human-corpus-tests.XXXXXX") \
    || fail "could not create self-test directory"
  chmod 700 "$self_test_temp_directory"
  trap cleanup_self_test_temp EXIT
  trap 'exit 130' HUP INT TERM

  base_fixture="$self_test_temp_directory/valid"
  make_self_test_fixture "$base_fixture"
  expect_self_test_pass valid_fixture "$base_fixture"

  case_fixture="$self_test_temp_directory/manifest_replacement"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  expect_self_test_fail manifest_replacement "$case_fixture" "manifest changed after the immutable snapshot" self_test_replace_manifest_with_duplicates

  case_fixture="$self_test_temp_directory/duplicate_rows"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  manifest_path="$case_fixture/$MANIFEST_NAME"
  replacement_path="$manifest_path.replacement"
  sed -n '1,35p' "$manifest_path" >"$replacement_path"
  sed -n '1p' "$manifest_path" >>"$replacement_path"
  mv -f "$replacement_path" "$manifest_path"
  expect_self_test_fail duplicate_rows "$case_fixture" "sample_id values must be unique"

  case_fixture="$self_test_temp_directory/fake_audio"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  fake_path="$case_fixture/audio/en-HK/hvc_001.wav"
  printf '%s\n' 'not an audio file' >"$fake_path"
  fake_hash=$(shasum -a 256 "$fake_path" | awk '{print $1}')
  jq -c --arg hash "$fake_hash" 'if .sample_id == "hvc_001" then .sha256 = $hash else . end' \
    "$case_fixture/$MANIFEST_NAME" >"$case_fixture/manifest.replacement"
  mv -f "$case_fixture/manifest.replacement" "$case_fixture/$MANIFEST_NAME"
  expect_self_test_fail fake_audio "$case_fixture" "failed audio metadata or hash validation"

  case_fixture="$self_test_temp_directory/missing_intent"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  jq -c 'if .locale == "en-HK" and .expected_intent == "send_message" then .expected_intent = "search_history" | .expected_args = {q:"fictional project"} | .risk_level = "low" | .needs_confirmation = false else . end' \
    "$case_fixture/$MANIFEST_NAME" >"$case_fixture/manifest.replacement"
  mv -f "$case_fixture/manifest.replacement" "$case_fixture/$MANIFEST_NAME"
  expect_self_test_fail missing_intent "$case_fixture" "missing command coverage for send_message"

  case_fixture="$self_test_temp_directory/speaker_distribution"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  jq -c 'if .locale == "en-HK" then (.sample_id | capture("hvc_(?<n>[0-9]+)").n | tonumber) as $n | .speaker_id = (if $n <= 10 then "spk_aaaaaaaaaaaa" elif $n == 11 then "spk_bbbbbbbbbbbb" else "spk_cccccccccccc" end) else . end' \
    "$case_fixture/$MANIFEST_NAME" >"$case_fixture/manifest.replacement"
  mv -f "$case_fixture/manifest.replacement" "$case_fixture/$MANIFEST_NAME"
  expect_self_test_fail speaker_distribution_10_1_1 "$case_fixture" "speakers with fewer than 4 recordings"

  case_fixture="$self_test_temp_directory/invalid_timestamp"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  jq -c 'if .sample_id == "hvc_002" then .expected_args.due_at = "2026-02-30T10:30:00+08:00" else . end' \
    "$case_fixture/$MANIFEST_NAME" >"$case_fixture/manifest.replacement"
  mv -f "$case_fixture/manifest.replacement" "$case_fixture/$MANIFEST_NAME"
  expect_self_test_fail invalid_timestamp "$case_fixture" "semantically invalid RFC 3339 timestamp"

  case_fixture="$self_test_temp_directory/extra_audio"
  clone_self_test_fixture "$base_fixture" "$case_fixture"
  cp "$case_fixture/audio/en-HK/hvc_001.wav" "$case_fixture/audio/en-HK/extra.wav"
  expect_self_test_fail extra_audio "$case_fixture" "audio inventory does not exactly match manifest paths"

  printf '%s\n' 'All human voice corpus validator self-tests passed.'
}

corpus_input=""
provenance_reviewed=false
self_test_requested=false
while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --self-test)
      [[ "$self_test_requested" == "false" ]] || usage_error "--self-test was provided more than once"
      self_test_requested=true
      shift
      ;;
    --provenance-consent-reviewed)
      [[ "$provenance_reviewed" == "false" ]] || usage_error "--provenance-consent-reviewed was provided more than once"
      provenance_reviewed=true
      shift
      ;;
    --corpus-dir|--corpus-root)
      (($# >= 2)) || usage_error "$1 requires a value"
      [[ -z "$corpus_input" ]] || usage_error "the corpus directory was provided more than once"
      corpus_input=$2
      shift 2
      ;;
    --)
      shift
      (($# == 1)) || usage_error "expected exactly one corpus directory after --"
      [[ -z "$corpus_input" ]] || usage_error "the corpus directory was provided more than once"
      corpus_input=$1
      shift
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      [[ -z "$corpus_input" ]] || usage_error "expected exactly one corpus directory"
      corpus_input=$1
      shift
      ;;
  esac
done

if [[ "$self_test_requested" == "true" ]]; then
  [[ -z "$corpus_input" && "$provenance_reviewed" == "false" ]] \
    || usage_error "--self-test cannot be combined with corpus validation options"
  run_self_tests
  exit 0
fi

[[ -n "$corpus_input" ]] || usage_error "a corpus directory is required"
validate_corpus "$corpus_input" "$provenance_reviewed"
