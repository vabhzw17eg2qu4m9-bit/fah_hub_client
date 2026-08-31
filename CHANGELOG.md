# Changelog

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
