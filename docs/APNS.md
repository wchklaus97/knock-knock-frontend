# Real APNs setup (Knock Knock)

Until these are filled, the app uses **Dev Push inbox** (HTTP polling). That already works on your iPhone.

App display name: **Knock Knock**. Bundle ID: **`hk.knockknock.app`** (must match Apple Developer Identifier + Xcode + `APNS_BUNDLE_ID`).

## 1. Apple Developer

1. [developer.apple.com](https://developer.apple.com) → Account → **Keys**
2. Create a key with **Apple Push Notifications service (APNs)**
3. Download `AuthKey_XXXXXXXXXX.p8` (once only)
4. Note **Key ID** and **Team ID**

## 2. Files on this Mac

```bash
mkdir -p secrets
# copy the .p8 into secrets/
```

`secrets/` is gitignored.

## 3. `.env` in repo root

```env
PUSH_MODE=both
APNS_KEY_PATH=secrets/AuthKey_XXXXXXXXXX.p8
APNS_KEY_ID=your_key_id
APNS_TEAM_ID=your_team_id
APNS_BUNDLE_ID=hk.knockknock.app
APNS_PRODUCTION=false
```

Restart API: `pnpm dev:api` → `/health` should show `"apns_ready": true`.

## 4. Xcode (real device)

1. Open `apps/ios/VoiceAgentBridge.xcodeproj`
2. Signing: select your **Team** (paid Apple Developer needed for Push)
3. Signing & Capabilities → **+ Push Notifications**
4. Rebuild to iPhone; allow notifications when prompted
5. App registers a real 64-hex device token (not `dev-…`)

## 5. Verify

Trigger `needs_user` (MCP or CLI). You should get:

- System notification (APNs), and
- Dev Push inbox row (`PUSH_MODE=both`)

The server does not send simulator registrations to Apple, even when a simulator
reports a token-shaped value. APNs delivery is limited to physical iOS device rows
(`platform=ios`) with a 64-character hexadecimal token.

### Notes

- Free Personal Team often **cannot** enable Push; use a paid Developer account.
- Debug builds use **sandbox** APNs (`APNS_PRODUCTION=false`).
- Bundle ID must match Xcode + `APNS_BUNDLE_ID`.
