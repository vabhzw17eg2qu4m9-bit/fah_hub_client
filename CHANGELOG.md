# Changelog

## Unreleased

- Enrollment auth: first connect enrolls via `DAP_MASTER_SECRET`; the
  hub-issued client secret is persisted in `~/.dap/config.json`.
- `HubPlugin.inviteTo` / `connectTo`: dap_invite and dap_connect, including
  pending invites armed for offline names and auto-delivered on presence.
- WebSocket keepalive so long-lived hub connections survive idle periods.
- Zero-config startup: settings resolve from env (`DAP_HUB_URL`,
  `DAP_AGENT_NAME`, `DAP_KEY_PATH`, `DAP_CHANNELS_FILE`) >
  `~/.dap/config.json` > defaults; identity auto-created at
  `~/.dap/keys/fah/<name>.key`.
