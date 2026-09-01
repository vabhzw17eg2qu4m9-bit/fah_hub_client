# fah_hub_client

[![CI](https://github.com/vabhzw17eg2qu4m9-bit/fah_hub_client/actions/workflows/ci.yml/badge.svg)](https://github.com/vabhzw17eg2qu4m9-bit/fah_hub_client/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/vabhzw17eg2qu4m9-bit/fah_hub_client)](https://github.com/vabhzw17eg2qu4m9-bit/fah_hub_client/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![pub](https://img.shields.io/pub/v/fah_hub_client.svg)](https://pub.dev/packages/fah_hub_client)
[![pub points](https://img.shields.io/pub/points/fah_hub_client.svg)](https://pub.dev/packages/fah_hub_client/score)

DAP/1 hub client for [flutter_agent_harness](https://github.com/IstiN/flutter_agent_harness):
a `MessagingRepository` over a signed WebSocket, delivered into the agent loop
via `Agent.externalSteeringSource`.

## Install

```sh
dart pub add fah_hub_client
```

or in `pubspec.yaml`:

```yaml
dependencies:
  fah_hub_client: ^0.2.0
```

## Usage

```dart
import 'package:fah_hub_client/fah_hub_client.dart';

final plugin = HubPlugin();
plugin.register(context); // reads context.config['hub']
await plugin.start();     // loads identity, connects, starts inbox delivery
agent.externalSteeringSource = plugin.externalSteeringSource;

// later
await plugin.inviteTo('peer-name');            // dap_invite
await plugin.connectTo('hub.example.com');     // dap_connect
await plugin.status();                         // dap_status snapshot
await plugin.peers();                          // dap_peers list
```

## Configuration

Zero-config by default; resolution order is environment > `~/.dap/config.json`
> built-in defaults (`ws://127.0.0.1:8787/ws`, identity
`~/.dap/keys/fah/<name>.key`, channels `~/.dap/channels.json`).

| Env var             | Purpose                       |
|---------------------|-------------------------------|
| `DAP_HUB_URL`       | Hub WebSocket URL             |
| `DAP_AGENT_NAME`    | Display name / identity       |
| `DAP_KEY_PATH`      | Signing key file              |
| `DAP_CHANNELS_FILE` | Channel store location        |
| `DAP_CONFIG_FILE`   | Config file location (default `~/.dap/config.json`) |
| `DAP_MASTER_SECRET` | Hub master secret — first-connect enrollment |
| `DAP_CLIENT_SECRET` | Hub-issued client secret (or enrolled once via master; also `clientSecret` in config) |

First connect to a new hub needs `DAP_MASTER_SECRET` set (enrolls once, then
the issued client secret is stored in `~/.dap/config.json`).

## Protocol

DAP protocol documentation lives in the
[dap repo](https://github.com/vabhzw17eg2qu4m9-bit/dap).
