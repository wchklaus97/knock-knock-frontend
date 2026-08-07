#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/knock-knock-config.XXXXXX")"
TEMP_DB="$TEMP_ROOT/bridge.db"
trap 'rm -rf "$TEMP_ROOT"' EXIT

set +e
HTTP_OUTPUT="$(cd "$ROOT/apps/api" && env \
  NODE_ENV=production \
  JWT_SECRET=12345678901234567890123456789012 \
  PUBLIC_BASE_URL=http://insecure.example.test \
  CORS_ORIGIN=https://app.example.test \
  PUSH_MODE=dev \
  DATABASE_PATH="$TEMP_DB" \
  pnpm exec tsx -e 'import "./src/config.ts"' 2>&1)"
HTTP_STATUS=$?
set -e
test "$HTTP_STATUS" -ne 0
echo "$HTTP_OUTPUT" | grep -q 'PUBLIC_BASE_URL must use HTTPS'

set +e
APNS_OUTPUT="$(cd "$ROOT/apps/api" && env \
  NODE_ENV=production \
  JWT_SECRET=12345678901234567890123456789012 \
  PUBLIC_BASE_URL=https://bridge.example.test \
  CORS_ORIGIN=https://app.example.test \
  PUSH_MODE=apns \
  APNS_PRODUCTION=true \
  APNS_KEY_PATH="$TEMP_ROOT/missing.p8" \
  APNS_KEY_ID=missing \
  APNS_TEAM_ID=missing \
  DATABASE_PATH="$TEMP_DB" \
  pnpm exec tsx -e 'import "./src/config.ts"' 2>&1)"
APNS_STATUS=$?
set -e
test "$APNS_STATUS" -ne 0
echo "$APNS_OUTPUT" | grep -q 'Production APNs requires'

echo "production config smoke: fail-closed checks passed"
