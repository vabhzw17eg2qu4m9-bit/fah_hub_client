# fah_hub_client

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
  fah_hub_client: ^0.1.0
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

First connect to a new hub needs `DAP_MASTER_SECRET` set (enrolls once, then
the client secret is stored in `~/.dap/config.json`).

## Protocol

DAP protocol documentation lives in the
[dap repo](https://github.com/vabhzw17eg2qu4m9-bit/distributed_agents).
