# Changelog

## 0.2.2

- Closed 0.2.1's residual first-query steal window: `HubClient` now
  fires a welcome-time warm-up `presence_query` on EVERY fresh
  connection — a throwaway whose only job is to make the hub echo
  `replyTo` and arm the echo-seen latch BEFORE any consumer query, so
  the startup join self-echo (a replyTo-less broadcast) can no longer
  drain the first `peers()` with a one-agent roster. Up to 2 retries
  while the latch is still unarmed; legacy hubs (answers without
  `replyTo`) leave the latch unarmed and keep the one-completes-all
  path; a reconnect re-runs the warm-up (a no-op once armed — the
  latch stays client-lifetime). The warm-up result is discarded and
  send failures clean up their waiter (the whois pattern — a
  listener-less pending completer could surface as an unhandled
  async error at teardown). Value contract for concurrent user
  queries unchanged.

## 0.2.1

- Fixed the owner-reported presence race (bug 2026-08-31, FA "BUG 5"):
  an UNSOLICITED `presence` broadcast completing a pending
  `presence_query` waiter made `peers()` return ONLY the broadcast's
  agent instead of the answer's roster. `presenceQuery()` now sends a
  frame id; per the hub `replyTo` contract (additive, docs/protocol.md
  §presence) an ANSWER echoes that id in `replyTo` and completes only
  the matching waiters — concurrent queries keep their own ids. On a
  hub known to echo, replyTo-less `presence` frames are broadcasts and
  never complete waiters. Legacy hubs (no echo) keep the 0.1.4
  one-completes-all answer path — old deployments keep working; the
  residual window (a broadcast racing the FIRST query to a new hub,
  before any echo is seen) is documented on `HubClient._onPresence`.

## 0.2.0

- BREAKING (owner decision 2026-08-31): `peers()` takes NO parameters —
  the `includeOffline` flag is gone. It now ALWAYS returns online-only
  agents and marks our own entry with `AgentInfo.self == true` (self
  stays in the list, not excluded). `AgentInfo` gains the `self` field
  (default false); raw `presenceQuery()`/`whois` entries are unchanged.
  `HubPlugin.peers` and `HubMessagingRepository.peers` aligned to the
  same no-flag shape.

## 0.1.4

- Request doors (`whois`/`flush`/`presenceQuery`) now fan out to waiter
  LISTS: concurrent callers all complete with the answer. Previously a
  second caller clobbered the single completer and ORPHANED the first —
  the live hang was the 15s PendingInvites presence poller racing a
  tool's `peers()`, and an inbound-DM sender whois racing a `sendDm` to
  the same peer. 0.1.3's request timeouts and error-frame completion are
  unchanged (each caller keeps its own 10s cap; genuine hub silence
  still fails loudly).
- Ported the FA SilentHub acceptance suite (`test/silent_hub_test.dart`):
  5 scenarios — silent `presence_query`, silent `whois`, error-answered
  `presence_query`, and the two clobber races (poller-vs-tool
  `presenceQuery`, whois-vs-whois on one target) — asserting every
  request COMPLETES within 3s; with a healthy hub answering once, both
  concurrent callers must receive the answer.

## 0.1.3

- Request timeouts on `whois`/`flush`/`presenceQuery`
  (`HubClient.requestTimeout`, default 10 s): a hub that never answers
  no longer hangs the caller forever — the request fails loudly ("hub
  did not answer <op> …") and the pending slot is released so a late
  answer cannot complete a dead request.
- Hub `error` frames now also complete pending flush/presence requests
  (mirroring disconnect handling); previously they only surfaced on the
  `errors` stream and left the caller waiting — the CLI no longer hangs
  when the hub answers with an error.

## 0.1.2

- Ported FA review fixes (db65522): `HubIdentity.load` warns loudly and
  returns false when the key file cannot be locked to mode 0600
  (injectable `setPrivateMode`/`warn`); HKDF honors the RFC 5869
  255-block cap; `HubPlugin.isDefaultUrl` lets hosts keep zero-config
  default-hub connect failures quiet.
- Whole-tree `dart format`; CI gained a `dart format` gate.

## 0.1.1


- Enrollment auth: first connect enrolls via `DAP_MASTER_SECRET`; the
  hub-issued client secret is persisted in `~/.dap/config.json`.
- `HubPlugin.inviteTo` / `connectTo`: dap_invite and dap_connect, including
  pending invites armed for offline names and auto-delivered on presence.
- WebSocket keepalive so long-lived hub connections survive idle periods.
- Zero-config startup: settings resolve from env (`DAP_HUB_URL`,
  `DAP_AGENT_NAME`, `DAP_KEY_PATH`, `DAP_CHANNELS_FILE`) >
  `~/.dap/config.json` > defaults; identity auto-created at
  `~/.dap/keys/fah/<name>.key`.

## Unreleased
