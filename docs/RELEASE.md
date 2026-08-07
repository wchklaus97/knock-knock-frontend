# Knock Knock Release Candidate runbook

This is the current release path for the split repositories. The Rust Worker in
`knock-knock-backend` is the only production source of truth; the former Node API
and the old Caddy/Docker instructions are migration diagnostics only.

Current production endpoint:

```text
https://knock-knock-backend-production.wch-klaus.workers.dev
```

The Cloudflare Worker, D1 binding, production APNs configuration, and HTTPS
health checks are already deployed. Apple account credentials, App Store
Connect processing, and the user's phone taps remain external prerequisites.

## 1. Deploy the canonical Rust Worker

From the backend checkout, keep the real production config and secrets local or
in the deployment system; never commit them:

```bash
cd /path/to/knock-knock/backend
wrangler d1 migrations apply knock-knock --remote --config wrangler.production.toml
wrangler deploy --config wrangler.production.toml
./scripts/production-healthcheck.sh \
  https://knock-knock-backend-production.wch-klaus.workers.dev
```

Required Worker secrets are `JWT_SECRET`, `APNS_KEY`, `APNS_KEY_ID`, and
`APNS_TEAM_ID`. The checked-in `wrangler.production.toml.example` contains only
placeholders and the non-secret D1/URL shape.

The repository workflow runs the health check every ten minutes and opens a
`production-alert` GitHub issue on failure. The daily D1 backup workflow is
ready but requires the GitHub Actions secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` before it can access the remote database.

The old Docker/Caddy deployment is intentionally not the canonical path. If it
is used for migration diagnostics, keep it single-replica with its SQLite
volume and do not point the production iOS build at it.

## 2. Prepare production APNs

- Apple Developer Identifier: `hk.knockknock.app`
- Release entitlement: `aps-environment=production`
- API: `APNS_PRODUCTION=true`, `PUSH_MODE=apns` (or `both` during a staged
  migration)

The API refuses to start in production if the `.p8` key, key ID, team ID, or
HTTPS base URL is missing. The phone registers only the physical 64-hex APNs
token; simulator placeholders are never sent to Apple. Notification actions
include **Review decision** and **Not now**.

## 3. Build and export the iOS archive

The release target uses manual Apple Distribution signing, the registered
`hk.knockknock.app` profile, the HTTPS Worker URL, and the production APNs
entitlement. The archive script defaults to Build21-style TestFlight export;
override the variables for another build:

```bash
DEVELOPMENT_TEAM=TXKDW2YS44 IOS_BUILD_NUMBER=22 pnpm release:ios
```

The script generates the Xcode project, archives a generic iOS device, and
exports/uploads according to `apps/ios/ExportOptions-TestFlight.plist`. To
export without uploading, set `IOS_EXPORT_OPTIONS_PLIST` to a local export
plist. The script also accepts `IOS_CODE_SIGN_IDENTITY`,
`IOS_PROVISIONING_PROFILE_SPECIFIER`, and `IOS_SIGNING_STYLE` overrides.

Before submitting, verify the archive's bundle ID is `hk.knockknock.app`, the
marketing version is correct, the production APNs entitlement is present, and
the API URL used by the release configuration is the HTTPS host.

## 4. TestFlight → App Store

1. Create the `hk.knockknock.app` app record in App Store Connect.
2. Upload the exported IPA.
3. Add internal testers and verify: sign in → pair an agent → receive a real
   APNs knock → use a destructive confirmation → agent receives the result.
4. Promote the verified build from TestFlight to App Review when metadata,
   privacy details, support URL, and review notes are complete.

The repository cannot submit on the owner's behalf without App Store Connect
credentials and the Apple Developer signing account. That is the only manual
part of this release path.

## 5. Rollback and observation

- Keep the previous Worker version ID and a recent D1 export before a migration.
- Roll back the Worker using Wrangler's version/deployment controls; do not
  delete the D1 database.
- Inspect `/health`, `/metrics`, and Cloudflare Worker logs after each release.
- Rotate a leaked agent key with `POST /v1/agents/{agent_id}/rotate-key` and
  revoke user refresh tokens by signing the user out on devices.
