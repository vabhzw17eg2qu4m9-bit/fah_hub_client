/// Request-door hardening (the CLI-hang incident): whois/flush/
/// presenceQuery must never hang on a hub that stays silent, and hub
/// `error` frames must complete the pending flush/presence requests
/// instead of being dropped on the floor.
///
/// The suite injects a 100 ms [HubClient.requestTimeout] so the hang
/// paths fail in milliseconds instead of the production 10 s; the fake
/// hub answers on the same event loop, so a 100 ms cap cannot fire
/// before a legitimate reply.
library;

import 'dart:async';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final shortRequestTimeout = Duration(milliseconds: 100);

Future<HubClient> connect(FakeHub hub) async {
  final client = HubClient(
    config: HubConfig(url: hub.url.toString()),
    identity: await HubIdentity.generate(),
    backoff: (int _) => const Duration(milliseconds: 5),
    requestTimeout: shortRequestTimeout,
  );
  await client.connect();
  // welcomeEvents fires after the post-welcome mailbox flush settles —
  // without this barrier a test flush() would race it for the single
  // _flushCompleter slot and be orphaned (pre-existing single-slot
  // design, not what these tests exercise).
  await client.welcomeEvents.first;
  return client;
}

void main() {
  late FakeHub hub;
  late HubClient client;

  setUp(() async {
    hub = FakeHub();
    await hub.start();
  });

  tearDown(() async {
    await client.disconnect();
    await hub.stop();
  });

  test('whois against a silent hub times out loudly, door stays usable',
      () async {
    client = await connect(hub);
    hub.silentOps.add('whois');

    await expectLater(
      client.whois(client.agentId!),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('hub did not answer whois'))),
    );

    // The timed-out request released its pending slot: with the silence
    // lifted, the next whois answers normally instead of hanging.
    hub.silentOps.clear();
    final info = await client.whois(client.agentId!);
    expect(info.agentId, client.agentId);
  }, timeout: timeout);

  test('flush answered with an error frame completes with that error',
      () async {
    client = await connect(hub);
    hub.errorOps.add('flush');

    final sawError = Completer<HubError>();
    client.errors.listen(sawError.complete); // errors stream still fires

    // Error frames used to be dropped for flush — the caller hung forever.
    await expectLater(
      client.flush(),
      throwsA(isA<HubError>()
          .having((e) => e.code, 'code', 'unsupported_op')
          .having((e) => e.msg, 'msg', 'fake hub rejects flush')),
    );
    expect(sawError.future, completion(isA<HubError>()));
  }, timeout: timeout);

  test('presence_query answered with an error frame completes with it',
      () async {
    client = await connect(hub);
    hub.errorOps.add('presence_query');

    await expectLater(
      client.presenceQuery(),
      throwsA(isA<HubError>().having((e) => e.code, 'code', 'unsupported_op')),
    );
  }, timeout: timeout);

  test('silent flush times out and a later flush still drains', () async {
    client = await connect(hub);
    hub.silentOps.add('flush');

    await expectLater(
      client.flush(),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('hub did not answer flush'))),
    );

    hub.silentOps.clear();
    expect(await client.flush(), 0); // slot was released, door works
  }, timeout: timeout);

  test('silent presence_query times out and a later query still answers',
      () async {
    client = await connect(hub);
    hub.silentOps.add('presence_query');

    await expectLater(
      client.presenceQuery(),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('hub did not answer presence_query'))),
    );

    hub.silentOps.clear();
    final agents = await client.presenceQuery();
    expect(agents.map((a) => a.agentId), contains(client.agentId));
  }, timeout: timeout);
}
