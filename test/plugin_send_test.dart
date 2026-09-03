/// HubPlugin.sendToChannel parity tests (the omp plugin's
/// `dap_send {channel, text}` path): the start guard, the zero-config
/// keygen + join on the first send to an unknown channel (hub relays the
/// op send frame), and honest failure when disconnected.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));

void main() {
  test(
    'sendToChannel before start(): honest StateError, not silence',
    () async {
      final plugin = HubPlugin(environment: {envMasterSecret: 'm'});
      plugin.register(PluginContext());
      expect(plugin.sendToChannel('general', 'hi'), throwsStateError);
    },
    timeout: timeout,
  );

  test(
    'sendToChannel round-trip: zero-config keygen + join, hub relays',
    () async {
      final hub = FakeHub();
      await hub.start();
      addTearDown(() => hub.stop());
      final home = await Directory.systemTemp.createTemp('fah-send-');
      addTearDown(() => home.delete(recursive: true));
      final channelsFile = '${home.path}/channels.json';

      // A bystander member of #general with its own (mismatched) keypair:
      // receiving the relay proves the send frame hit the hub.
      final bystanderKeys = await X25519().newKeyPair();
      final bystanderPub = base64Encode(
        (await bystanderKeys.extractPublicKey()).bytes,
      );
      final bystander = HubClient(
        config: HubConfig(
          url: hub.url.toString(),
          channels: {'general': bystanderPub},
          channelSecrets: {
            'general': base64Encode(
              await bystanderKeys.extractPrivateKeyBytes(),
            ),
          },
        ),
        identity: await HubIdentity.generate(),
      );
      await bystander.connect();
      addTearDown(() => bystander.disconnect());

      final plugin = HubPlugin(
        environment: {envChannelsFile: channelsFile, envMasterSecret: 'm'},
        home: home.path,
      );
      plugin.register(
        PluginContext(
          config: {
            'hub': {'url': hub.url.toString(), 'name': 'sender'},
          },
        ),
      );
      await plugin.start();
      addTearDown(() => plugin.dispose());

      // The store starts empty: the first send must create the channel.
      expect(plugin.repository!.client.channelStore?.pubOf('general'), isNull);
      final relayed = bystander.inbound
          .firstWhere((m) => m.from == plugin.agentId)
          .timeout(const Duration(seconds: 5));
      final joined = hub.joins
          .firstWhere(
            (j) => j.channel == 'general' && j.agentId == plugin.agentId,
          )
          .timeout(const Duration(seconds: 5));
      await plugin.sendToChannel('general', 'hi from the plugin');

      expect((await joined).agentId, plugin.agentId); // zero-config auto-join
      await relayed; // hub relayed the send frame

      expect(hub.deliveredTo, [bystander.agentId]); // sender not echoed
      final frame = hub.relayed.single;
      expect(frame['op'], 'send');
      expect(frame['channel'], 'general');
      // hub routed ciphertext only
      expect(jsonEncode(frame), isNot(contains('hi from the plugin')));
      // the fresh keypair landed in the store and on disk for next launch
      final stored = await loadChannelKeys(channelsFile);
      expect(stored['general'], isNotNull);
      expect(
        plugin.repository!.client.channelStore?.pubOf('general'),
        stored['general']!.pub,
      );
    },
    timeout: timeout,
  );

  test('honest failure: sendToChannel while disconnected throws', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await Directory.systemTemp.createTemp('fah-send-off-');
    addTearDown(() => home.delete(recursive: true));

    final plugin = HubPlugin(
      environment: {
        envChannelsFile: '${home.path}/channels.json',
        envMasterSecret: 'm'
      },
      home: home.path,
    );
    plugin.register(
      PluginContext(
        config: {
          'hub': {'url': hub.url.toString(), 'name': 'offline'},
        },
      ),
    );
    await plugin.start();
    addTearDown(() => plugin.dispose());
    await plugin.repository!.client.disconnect();
    await expectLater(
      plugin.sendToChannel('general', 'anyone?'),
      throwsA(isA<StateError>()),
    );
  }, timeout: timeout);
}
