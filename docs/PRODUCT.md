# Knock Knock — Product Scope and Base Architecture

**Status:** Baseline product definition for the standalone iOS app

**Product name:** Knock Knock

**Repository/code name:** `voice-agent-bridge`

## 1. Product definition

Knock Knock is a trusted decision inbox for coding agents. When an agent is
blocked and needs a human choice, it sends a structured decision to the
user's iPhone. The user reviews the context, chooses an explicit action, and
the answer returns to the exact requesting agent session.

Knock Knock is not a general chat app, an AI coding agent, or an agent
execution environment. The iPhone is the decision surface; the agent host
remains responsible for doing the work.

### Product promise

> When my coding agent needs me, I can understand the decision and respond
> safely from my phone, even if the app was not open when the request arrived.

## 2. Baseline architecture decision

The standalone iOS app uses a hybrid delivery model:

| App state | Primary mechanism | Purpose |
|---|---|---|
| Foreground | SSE | Receive live decision and session events without 2-second polling |
| Background / suspended | APNs | Notify the user that attention is needed |
| App launch or foreground resume | REST full sync | Reconcile all state and recover events missed while suspended |
| User actions | REST API | Submit safe, confirmed, idempotent decisions |
| SSE unavailable | Low-frequency fallback polling | Preserve basic functionality during an outage |

### Lifecycle contract

1. After authentication, the app performs an initial REST sync.
2. When the scene becomes active, the app performs a reconciliation sync and
   opens one authenticated SSE connection.
3. While the app is active, the server sends events only when relevant state
   changes. The connection uses heartbeats and automatic reconnect with
   backoff.
4. When the app enters the background, the app closes SSE and does not start a
   2-second polling loop.
5. For a new `needs_user` decision, the server sends an APNs notification to
   registered physical devices. A notification contains the session/event
   identifiers needed to open the exact decision.
6. When the user taps the notification or returns to the app, the app performs
   a REST reconciliation sync, opens the decision if it still exists, and then
   reconnects SSE.
7. The client stores the last applied event cursor (`event_id` or equivalent)
   and uses it during reconnect/reconciliation so events are not silently
   lost or applied twice.

### Delivery rules

- SSE is a foreground live-update channel, not a background execution mode.
- APNs is the background attention channel, not the source of truth.
- REST state is authoritative after every resume, notification tap, action,
  reconnect, and manual refresh.
- Silent APNs (`content-available`) may improve cache freshness, but delivery
  is best effort and cannot be the only recovery path.
- Do not enable Audio, Location, or VoIP background modes to keep SSE alive.
- Actions remain idempotent and bound to `session_id` plus `action_id`.

### Target transport contract

The exact route names may evolve with the API contract, but the product needs
these capabilities:

| Capability | Target contract |
|---|---|
| Initial/reconciliation state | Authenticated REST endpoints for sessions, agents, and device state |
| Live events | Authenticated `text/event-stream` endpoint scoped to the user |
| Event resume | `Last-Event-ID` header or an equivalent `since` cursor |
| Live event identity | Stable event id, event type, session id, and server timestamp |
| User decision | Authenticated REST action endpoint with idempotency |
| Background attention | APNs alert containing a safe summary and session id |
| Manual refresh | Explicit full REST sync initiated by the user |

## 3. MVP scope

The MVP proves one complete workflow:

> Agent asks → phone receives → user understands → user confirms or chooses →
> exact agent session receives the result.

### P0 — must ship

#### Identity and trusted pairing

- Email/password authentication through the production auth service.
- Secure access/refresh token lifecycle.
- One-time agent pairing code.
- A trusted-agent list with revoke and rotate controls.
- Clear sign-out and device trust state.

#### Decision inbox

- Default signed-in screen showing decisions that need the user.
- Needs me, Active, and All filters.
- Agent name, skill, task summary, risk, age, and current state.
- Unread/read state and a clear last-synced/offline state.
- Stable loading, empty, offline, expired, and unavailable states.

#### Decision detail and safety

- Agent and skill identity.
- Relevant facts, impact, risk, and expiry information.
- Explicit action buttons with plain-language labels.
- A second confirmation step for destructive actions.
- Result states: queued, claimed, completed, cancelled, failed, or expired.
- A visible trust cue that the answer returns to the exact agent session.

#### Live delivery and recovery

- Foreground SSE connection.
- SSE heartbeat, reconnect backoff, authentication renewal, and cursor resume.
- Full REST sync on launch, foreground resume, notification tap, and manual refresh.
- APNs alert for a new decision that needs the user.
- Notification deep link to the exact session.
- Low-frequency fallback when SSE is unavailable.

#### Agent interoperability

- MCP server and CLI decision contract.
- Codex as the canonical P0 host.
- Cursor and Paperclip support kept behind the same versioned contract.
- Exact session continuity across agent restarts and phone reconnects.

#### Settings and diagnostics

- Connection health and last successful sync.
- Trusted agents and pairing controls.
- Notification permission and APNs registration status.
- Advanced diagnostics behind a disclosure.
- About, build information, and sign-out.

#### Initial commercial model

- One paid plan only: **Knock Knock Pro**.
- Suggested launch price: `$2.99/month` or `$29.99/year`.
- Three-day trial starts after the first agent is successfully paired, not at
  account creation.
- No Team, Business, usage-metered, or add-on plans in the MVP.
- The app may be downloaded free, but Pro features require an active trial or
  subscription.

### P1 — after the core workflow is proven

- Better inbox ranking by urgency, risk, and age.
- Notification categories and actionable notification buttons.
- Offline read cache and a visible event-reconciliation history.
- QR/deep-link pairing.
- Per-user quiet hours and notification preferences.
- More agent hosts and a one-command installer.
- Subscription management and a small amount of product analytics.

### P2 — deliberately deferred

- Team workspaces, shared inboxes, RBAC, SSO, and enterprise retention.
- Advanced audit exports and compliance packages.
- Agent execution, model selection, code editing, or chat replacement.
- Voice conversations, file attachments, and rich media.
- Continuous background connections.
- High-frequency polling as a primary transport.
- Multiple pricing tiers or complex usage billing.

## 4. Core user flows

### First-time setup

1. User installs the standalone iOS app.
2. User signs in or creates an account.
3. User grants notification permission.
4. User pairs the first agent with a one-time code or QR/deep link.
5. App confirms the trusted connection and starts the Pro trial clock.
6. App performs an initial sync and opens the foreground SSE channel.

### Foreground decision

1. Agent reports `needs_user`.
2. Backend persists the event and makes it available on the user's SSE stream.
3. App updates the inbox without a timed polling loop.
4. User opens the exact session.
5. User selects a safe action or confirms a destructive action.
6. App submits the idempotent REST action.
7. Agent claims and receives the result.
8. App shows the terminal routing/result state.

### Background decision

1. App closes SSE when suspended.
2. Agent reports `needs_user`.
3. Backend persists the event and sends an APNs alert.
4. User taps the notification.
5. App authenticates if needed, performs a full reconciliation sync, and opens
   the exact session.
6. App reconnects SSE after the foreground sync completes.

### Reconnect and recovery

1. SSE disconnects or returns an authentication error.
2. App refreshes the access token once when appropriate.
3. App reconnects with the last event cursor and exponential backoff.
4. App performs a REST reconciliation if the cursor is missing, rejected, or
   the stream was unavailable while the app was suspended.
5. Duplicate events are ignored by stable event id; actions remain safe through
   server-side idempotency.

## 5. Product surfaces

### Welcome and pairing

Explain the product in one sentence, show the security promise, and make the
first successful agent connection the main activation moment.

### Inbox

Answer “what needs me right now?” immediately. Use orange only for attention
or risk; use neutral surfaces for ordinary state. Do not use generic chat
bubbles.

### Decision detail

Make the context and consequence clear before the action. The user should see
who asked, what will happen, whether the action is reversible, and whether a
second confirmation is required.

### Settings

Keep operational settings visible and development-only controls hidden behind
Advanced. Show connection health, notification status, trusted agents, pairing,
and account controls.

## 6. Success metrics

### Primary metric

**First-value activation:** percentage of new users who pair an agent and
complete one decision within 24 hours.

Initial target: **60%** after onboarding and transport stabilization.

### Reliability metrics

- Foreground event-to-inbox update: P95 under 2 seconds.
- No lost decision after background resume, notification tap, or SSE reconnect.
- Action submission success: at least 99% excluding explicit user cancellation.
- Duplicate action rate: zero server-accepted duplicates.
- APNs registration success on supported physical devices.

### Product metrics

- Trial-to-paid conversion.
- Three-day trial completion and first-decision completion.
- 7-day and 30-day retention.
- Number of decisions completed per active user.
- Support tickets caused by pairing, notification, or connection failure.

### Guardrails

- No access token or agent key in logs, notification text, or SSE URL query
  parameters.
- No destructive action without the required confirmation.
- No background polling loop or unsupported background mode added to preserve
  SSE.
- No production release that relies only on Dev Push or a LAN URL.

## 7. Current implementation status

The first vertical slice is now implemented across the production Worker and
iOS app:

- `GET /v1/phone/events` is authenticated and user-scoped.
- The stream sends `sync.required` and `session.updated` invalidations with a
  stable `updated_at|session_id` cursor, heartbeats, and bounded reconnects.
- iOS uses the generic `ServerSentEventsTransport<Payload>` class with
  `SessionInvalidation` as the default payload.
- iOS performs REST reconciliation after live events, on foreground resume,
  notification taps, and manual refresh.
- iOS closes SSE and the temporary 60-second fallback refresh when entering
  the background; APNs remains the background attention path.
- Access-token renewal, exponential reconnect, and cursor persistence are in
  the client.

This first transport is intentionally stateless and D1-backed. Before opening
the service to 10,000 simultaneous foreground users, replace the bounded D1
cursor loop with Durable Object or equivalent fan-out and run the load test.
That upgrade does not change the iOS generic transport or the REST contract.

Remaining rollout sequence:

1. Add lifecycle, reconnect, duplicate-event, notification-tap, and physical
   device tests.
2. Add stream metrics and verify APNs delivery on hosted HTTPS.
3. Run the 1,000-connection load test before production rollout.
4. Run the 10,000-connection test before scaling beyond the initial launch
   cohort, then enable Durable Object fan-out if the measured load requires it.

## 8. Definition of done for the baseline architecture

- A foreground user receives a new decision without a 2-second polling loop.
- A background user receives an APNs notification for a new decision.
- Tapping the notification opens the correct session after reconciliation.
- Closing and reopening the app does not lose or duplicate events.
- An expired access token is renewed without losing the stream state.
- A manual refresh always performs an authoritative REST sync.
- A failed SSE connection falls back safely and reports connection state.
- Destructive actions remain protected by confirmation and idempotency.
- Dev Push is never the only production delivery path.
- The standalone iPhone workflow passes on a physical device over hosted HTTPS.
