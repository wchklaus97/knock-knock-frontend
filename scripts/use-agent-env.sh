#!/usr/bin/env bash
# Compatibility shim for the retired shell credential bootstrap.

_KNOCK_LEGACY_BOOTSTRAP_MESSAGE="Legacy environment bootstrap is disabled; run scripts/knock-codex-listener.sh so credential loading stays inside the hardened client."

if [[ -n "${ZSH_EVAL_CONTEXT:-}" && "${ZSH_EVAL_CONTEXT}" == *:file ]] ||
  [[ -n "${BASH_VERSION:-}" && "${BASH_SOURCE[0]:-}" != "$0" ]]; then
  printf '%s\n' "$_KNOCK_LEGACY_BOOTSTRAP_MESSAGE" >&2
  unset _KNOCK_LEGACY_BOOTSTRAP_MESSAGE
  return 1
fi

set -euo pipefail

script_path="${BASH_SOURCE[0]}"
case "$script_path" in
  */*) script_parent="${script_path%/*}" ;;
  *) script_parent="." ;;
esac

if ! script_directory="$(cd -P -- "$script_parent" && pwd -P)"; then
  printf '%s\n' "$_KNOCK_LEGACY_BOOTSTRAP_MESSAGE" >&2
  exit 1
fi

listener="$script_directory/knock-codex-listener.sh"
if [[ ! -f "$listener" || -L "$listener" || ! -O "$listener" || ! -r "$listener" ]]; then
  printf '%s\n' "$_KNOCK_LEGACY_BOOTSTRAP_MESSAGE" >&2
  exit 1
fi

exec /bin/bash --noprofile --norc "$listener" "$@"
printf '%s\n' "$_KNOCK_LEGACY_BOOTSTRAP_MESSAGE" >&2
exit 1
