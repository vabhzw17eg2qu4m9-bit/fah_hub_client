/// Master-secret enrollment auth (wire contract): bearer token on every
/// dial (master secret or hub-issued client secret), 401 rejection with
/// the frozen cross-adapter text, and the enroll-once flow — the hub
/// issues a client secret, the client persists it to `~/.dap/config.json`
/// and uses it for every later dial.
library;

import 'dart:async';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final tinyBackoff = (int _) => const Duration(milliseconds: 5);

/// Terminal capture ([PluginIO] seam) with a per-line hook so tests can
/// await notices event-driven.
class _CaptureIO implements PluginIO {
  final lines = <String>[];

  void Function(String line)? onLine;

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) {
    lines.add(text);
    onLine?.call(text);
  }
}

void main() {
  test(
      'token precedence: DAP_CLIENT_SECRET > config clientSecret > '
      'DAP_MASTER_SECRET (enroll)', () {
    const stored = {'clientSecret': 'stored'};
    expect(
      resolveDapClientSecret(
        environment: const {
          'DAP_CLIENT_SECRET': 'env-client',
          'DAP_MASTER_SECRET': 'master',
        },
        config: stored,
      ),
      (
        token: 'env-client',
        enroll: false,
        source: DapSecretSource.env,
        master: 'master',
      ),
    );
    expect(
      resolveDapClientSecret(
          environment: const {'DAP_MASTER_SECRET': 'master'}, config: stored),
      (
        token: 'stored',
        enroll: false,
        source: DapSecretSource.config,
        master: 'master',
      ),
    );
    expect(
      resolveDapClientSecret(
          environment: const {'DAP_MASTER_SECRET': 'master'}),
      (
        token: 'master',
        enroll: true,
        source: DapSecretSource.master,
        master: 'master',
      ),
    );
    expect(resolveDapClientSecret(), (
      token: null,
      enroll: false,
      source: DapSecretSource.none,
      master: null,
    ));
    // Empty env values count as absent.
    expect(
      resolveDapClientSecret(environment: const {
        'DAP_CLIENT_SECRET': '',
        'DAP_MASTER_SECRET': 'm'
      }),
      (
        token: 'm',
        enroll: true,
        source: DapSecretSource.master,
        master: 'm',
      ),
    );
  }, timeout: timeout);

  test('dial carries Authorization: Bearer <resolved secret>', () async {
    final hub = FakeHub(masterSecret: 'issued-to-bee');
    await hub.start();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: await HubIdentity.generate(),
      clientSecret: 'issued-to-bee',
    );
    try {
      await client.connect();
      expect(hub.dialAuths, ['Bearer issued-to-bee']);
      expect(hub.enrollCount, 0); // a client secret never enrolls
      expect(hub.hellosSeen, 1);
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('401 bearer rejection surfaces HubError with the frozen text, once',
      () async {
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      clientSecret: 'stale-secret',
      backoff: tinyBackoff,
    );
    try {
      await expectLater(
        client.connect(),
        throwsA(isA<HubError>()
            .having((e) => e.code, 'code', 'unauthorized')
            .having(
                (e) => e.msg,
                'msg',
                'hub rejected connection (HTTP 401): set DAP_MASTER_SECRET '
                    'to enroll, or DAP_CLIENT_SECRET / config clientSecret '
                    'to connect')),
      );
      expect(hub.dialAuths, ['Bearer stale-secret']);
      // Fatal: no retry storm against a 401.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.dialAuths, hasLength(1));
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test(
      'master-secret dial enrolls once, persists the issued secret, and '
      'reconnects with it', () async {
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-enroll-');
    addTearDown(() => home.delete(recursive: true));
    final cfgFile = '${home.path}/.dap/config.json';
    final enrolled = Completer<void>();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: await HubIdentity.generate(),
      clientSecret: 'hub-master',
      enroll: true,
      configFile: cfgFile,
      backoff: tinyBackoff,
      onNotice: (notice) {
        if (notice == 'enrolled: client secret persisted' &&
            !enrolled.isCompleted) {
          enrolled.complete();
        }
      },
    );
    try {
      await client.connect();
      expect(hub.dialAuths.single, 'Bearer hub-master');
      await enrolled.future.timeout(const Duration(seconds: 5));
      expect(readDapConfig(cfgFile)['clientSecret'], hub.issuedSecret);
      expect(hub.issuedName, 'bee');
      expect(hub.enrollCount, 1);

      // Drop the socket: the reconnect dials with the ISSUED secret —
      // accepted (hello bound to the enrolling name) without re-enrolling.
      final offline =
          hub.agentOffline.first.timeout(const Duration(seconds: 5));
      await hub.closeAgent(client.agentId!);
      await offline;
      await hub.waitForHellos(2);
      expect(hub.dialAuths.last, 'Bearer ${hub.issuedSecret}');
      expect(hub.enrollCount, 1);
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test(
      'stale config clientSecret + master: drops the cache, re-enrolls '
      'once, persists the new secret, identity untouched', () async {
    // Restarted hub: server-side secrets wiped, only the master secret
    // is known — the persisted client cache 401s on sight.
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-stale-');
    addTearDown(() => home.delete(recursive: true));
    final keyPath = '${home.path}/.dap/keys/fah/bee.key';
    final identity = await HubIdentity.load(keyPath);
    final keyBytes = await File(keyPath).readAsBytes();
    final cfgFile = '${home.path}/.dap/config.json';
    await persistDapConfig(clientSecret: 'stale-cache', file: cfgFile);
    final persisted = Completer<void>();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: identity,
      clientSecret: 'stale-cache',
      secretSource: DapSecretSource.config,
      masterSecret: 'hub-master',
      configFile: cfgFile,
      backoff: tinyBackoff,
      onNotice: (notice) {
        if (notice == 'enrolled: client secret persisted' &&
            !persisted.isCompleted) {
          persisted.complete();
        }
      },
    );
    try {
      final agentId = await client.connect();
      expect(agentId, identity.agentId); // same key -> same agent id
      expect(hub.dialAuths,
          ['Bearer stale-cache', 'Bearer hub-master']); // one escalation
      await persisted.future.timeout(const Duration(seconds: 5));
      expect(hub.enrollCount, 1);
      expect(hub.issuedSecret, isNot('stale-cache'));
      expect(hub.issuedName, 'bee'); // re-enroll bound to the hello name
      expect(readDapConfig(cfgFile)['clientSecret'], hub.issuedSecret);
      expect(await File(keyPath).readAsBytes(), keyBytes); // key untouched
      // Settled: no third dial, no loop.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.dialAuths, hasLength(2));
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('stale ENV clientSecret + master: hard fail, config untouched',
      () async {
    // Restarted hub: it knows neither the env secret nor anything else.
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-env-');
    addTearDown(() => home.delete(recursive: true));
    final cfgFile = '${home.path}/.dap/config.json';
    await persistDapConfig(url: 'ws://example/ws', name: 'bee', file: cfgFile);
    final before = await File(cfgFile).readAsString();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: await HubIdentity.generate(),
      clientSecret: 'env-secret',
      secretSource: DapSecretSource.env,
      masterSecret: 'hub-master',
      configFile: cfgFile,
      backoff: tinyBackoff,
    );
    try {
      await expectLater(
        client.connect(),
        throwsA(isA<HubError>()
            .having((e) => e.code, 'code', 'unauthorized')
            .having((e) => e.msg, 'msg', unauthorizedMsg)),
      );
      expect(hub.dialAuths, ['Bearer env-secret']); // env never retried
      expect(await File(cfgFile).readAsString(), before);
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('stale config clientSecret, no master: hard fail, cache kept', () async {
    // Restarted hub: it does not know the persisted cache secret.
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-nomaster-');
    addTearDown(() => home.delete(recursive: true));
    final cfgFile = '${home.path}/.dap/config.json';
    await persistDapConfig(clientSecret: 'stale-cache', file: cfgFile);
    final before = await File(cfgFile).readAsString();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: await HubIdentity.generate(),
      clientSecret: 'stale-cache',
      secretSource: DapSecretSource.config,
      configFile: cfgFile,
      backoff: tinyBackoff,
    );
    try {
      await expectLater(
        client.connect(),
        throwsA(isA<HubError>()
            .having((e) => e.code, 'code', 'unauthorized')
            .having((e) => e.msg, 'msg', unauthorizedMsg)),
      );
      expect(hub.dialAuths, ['Bearer stale-cache']);
      expect(readDapConfig(cfgFile)['clientSecret'], 'stale-cache');
      expect(await File(cfgFile).readAsString(), before);
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('re-enroll retry also 401s: fatal with the frozen hint, no loop',
      () async {
    // Restarted hub whose master differs from the client's: the
    // escalation's enroll-mode retry 401s too.
    final hub = FakeHub(masterSecret: 'real-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-retry-');
    addTearDown(() => home.delete(recursive: true));
    final cfgFile = '${home.path}/.dap/config.json';
    await persistDapConfig(clientSecret: 'stale-cache', file: cfgFile);
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bee'),
      identity: await HubIdentity.generate(),
      clientSecret: 'stale-cache',
      secretSource: DapSecretSource.config,
      masterSecret: 'wrong-master',
      configFile: cfgFile,
      backoff: tinyBackoff,
    );
    try {
      await expectLater(
        client.connect(),
        throwsA(isA<HubError>()
            .having((e) => e.code, 'code', 'unauthorized')
            .having((e) => e.msg, 'msg', unauthorizedMsg)),
      );
      // The provably dead cache is gone, the file stays valid JSON.
      expect(readDapConfig(cfgFile).containsKey('clientSecret'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.dialAuths, hasLength(2)); // no loop
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test(
      'HubPlugin: DAP_MASTER_SECRET enrolls once and persists the issued '
      'client secret to the injected config', () async {
    final hub = FakeHub(masterSecret: 'hub-master');
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-plugin-');
    addTearDown(() => home.delete(recursive: true));
    final io = _CaptureIO();
    final persisted = Completer<void>();
    io.onLine = (line) {
      if (line == '[hub] enrolled: client secret persisted' &&
          !persisted.isCompleted) {
        persisted.complete();
      }
    };
    final plugin = HubPlugin(
      environment: {'DAP_MASTER_SECRET': 'hub-master'},
      home: home.path,
    );
    plugin.register(PluginContext(config: {
      'hub': {'url': hub.url.toString(), 'name': 'bee'},
    }, io: io));
    try {
      await plugin.start();
      await persisted.future.timeout(const Duration(seconds: 5));
      expect(readDapConfig('${home.path}/.dap/config.json')['clientSecret'],
          hub.issuedSecret);
      expect(hub.issuedName, 'bee');
      expect(hub.dialAuths.single, 'Bearer hub-master');
      expect(io.lines.join('\n'), isNot(contains(hub.issuedSecret)));
    } finally {
      await plugin.dispose();
      await hub.stop();
    }
  }, timeout: timeout);

  test('dap_connect output gains the enroll hint line', () async {
    final hub = FakeHub();
    await hub.start();
    final home = await Directory.systemTemp.createTemp('fah-dap-hint-');
    addTearDown(() => home.delete(recursive: true));
    final io = _CaptureIO();
    final plugin = HubPlugin(environment: const {}, home: home.path);
    plugin.register(PluginContext(config: {
      'hub': {'url': hub.url.toString()},
    }, io: io));
    try {
      await plugin.start();
      final before = io.lines.length;
      await plugin.connectTo('127.0.0.1:${hub.url.port}', name: 'roam');
      expect(io.lines.sublist(before), [
        '[hub] connected to ws://127.0.0.1:${hub.url.port}/ws as ${plugin.agentId}',
        '[hub] first connect needs DAP_MASTER_SECRET set '
            '(enrolls once, then stored)',
      ]);
    } finally {
      await plugin.dispose();
      await hub.stop();
    }
  }, timeout: timeout);
}
