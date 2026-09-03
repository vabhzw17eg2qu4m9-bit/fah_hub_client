/// DAP_MASTER_SECRET gate: without the env var (unset or empty) the
/// plugin is fully inert — no dial, no reconnect, no keepalive, no
/// presence poller, no output — and every public method fails with the
/// one honest error. With it set, behavior is unchanged (enroll + connect).
library;

import 'dart:async';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));

const disabledMsg = 'DAP_MASTER_SECRET is not set — DAP disabled';

class _CaptureIO implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);
}

Future<Directory> _tmpHome(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

HubPlugin _plugin(Map<String, String> environment, String home, Uri url,
        {PluginIO? io}) =>
    HubPlugin(environment: environment, home: home)
      ..register(PluginContext(config: {
        'hub': {'url': url.toString(), 'name': 'gated'},
      }, io: io));

void main() {
  test(
      'no DAP_MASTER_SECRET: start() dials nothing, starts nothing, '
      'prints nothing', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await _tmpHome('fah-dap-gate-off-');
    addTearDown(() => home.delete(recursive: true));
    final io = _CaptureIO();

    final plugin = _plugin(const {}, home.path, hub.url, io: io);
    await plugin.start();
    // Flush the event queue: a hidden reconnect timer would dial here.
    await Future<void>.delayed(Duration.zero);

    expect(hub.dialAuths, isEmpty); // no WebSocket connect attempt
    expect(hub.hellosSeen, 0);
    expect(io.lines, isEmpty); // no status/log output
    expect(plugin.repository, isNull);
    expect(plugin.agentId, isNull);
    await plugin.dispose();
  }, timeout: timeout);

  test('no DAP_MASTER_SECRET: every public method fails honestly',
      () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await _tmpHome('fah-dap-gate-err-');
    addTearDown(() => home.delete(recursive: true));

    // DAP_CLIENT_SECRET / config secrets do NOT unlock a gated plugin:
    // the gate is DAP_MASTER_SECRET alone.
    final plugin = _plugin(
        const {envClientSecret: 'client'}, home.path, hub.url);
    await plugin.start();
    expect(hub.dialAuths, isEmpty);

    await expectLater(plugin.inviteTo('carol'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', disabledMsg)));
    await expectLater(plugin.connectTo('127.0.0.1:${hub.url.port}'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', disabledMsg)));
    await expectLater(plugin.status(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', disabledMsg)));
    await expectLater(plugin.peers(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', disabledMsg)));
    await expectLater(plugin.sendToChannel('general', 'hi'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', disabledMsg)));
    expect(hub.dialAuths, isEmpty); // still nothing dialed
    await plugin.dispose();
  }, timeout: timeout);

  test('empty DAP_MASTER_SECRET counts as unset', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await _tmpHome('fah-dap-gate-empty-');
    addTearDown(() => home.delete(recursive: true));

    final plugin =
        _plugin(const {envMasterSecret: ''}, home.path, hub.url);
    await plugin.start();
    await Future<void>.delayed(Duration.zero);

    expect(hub.dialAuths, isEmpty);
    await expectLater(
        plugin.peers(),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', disabledMsg)));
    await plugin.dispose();
  }, timeout: timeout);

  test('DAP_MASTER_SECRET set: unchanged enroll + connect behavior',
      () async {
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await _tmpHome('fah-dap-gate-on-');
    addTearDown(() => home.delete(recursive: true));
    final io = _CaptureIO();

    final plugin =
        _plugin(const {envMasterSecret: 'hub-master'}, home.path, hub.url,
            io: io);
    await plugin.start();
    await hub.waitForHellos(1);

    expect(hub.dialAuths.single, 'Bearer hub-master'); // enroll dial
    expect(plugin.agentId, isNotNull);
    expect(io.lines, contains('[hub] connected as ${plugin.agentId}'));
    await plugin.dispose();
  }, timeout: timeout);
}
