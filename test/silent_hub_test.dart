/// Regression gate for the completer-clobber race (fah_hub_client 0.1.3):
/// a hub that stays SILENT at the application layer while the socket stays
/// open (pings/pongs flowing) must not wedge the client's request
/// completers, and a concurrent caller must never orphan an earlier one.
///
/// Reproduces the live incident: two `dap_dm` calls in one turn — the
/// first delivered, the second hung the whole CLI (spinner, ESC dead, no
/// inbound mail):
///
/// * BUG 1 — `whois()`/`flush()`/`presenceQuery()` completers have NO
///   timeout: a hub that never answers hangs the caller permanently while
///   the connection is healthy (the 20s ping watchdog never fires — the
///   socket is alive, the application just went quiet). FIXED in 0.1.3
///   (`requestTimeout`); kept honest here against the 3s bound.
/// * BUG 2 — `_onError` fails only `_pendingWhois`; flush/presence
///   requests are not completed on an error frame, so a hub that answers
///   `presence_query` with `error` hangs `peers()` forever. FIXED in
///   0.1.3 (`_failFlushPresence`); kept honest here.
/// * BUG 3 — `presenceQuery()` stores ONE completer in a single field: a
///   concurrent call (the 15s PendingInvites poller vs a tool's peer
///   resolve) overwrites it and ORPHANS the first caller — which then
///   awaits forever even though the hub answered every request. This is
///   the live incident's most likely trigger. FIXED in 0.1.4: waiter
///   LISTS fan out; an inbound presence frame completes EVERY current
///   waiter with the result.
/// * BUG 4 — same class for `_pendingWhois[target]`: an inbound DM's
///   sender resolution via whois() races a `sendDm` to the same peer; the
///   map held one completer per target, so the second write orphaned the
///   first. FIXED in 0.1.4: per-target waiter lists.
/// * BUG 5 (fah_hub_client 0.2.0, owner report 2026-08-31) —
///   `_onPresence` completed `_presenceWaiters` with whatever list ANY
///   `presence` frame carried: an UNSOLICITED one-agent broadcast (a
///   join push) landing between the query and its answer drained the
///   waiters first, so `peers()` returned a one-agent roster. FIXED in
///   0.2.1: `presence_query` carries a frame id; an ANSWER is recognized
///   by the hub echoing that id in `replyTo` and completes only the
///   matching waiters; on a hub known to echo, replyTo-less frames are
///   broadcasts and complete nothing; legacy hubs (never echo) keep
///   one-completes-all so old deployments keep working.
///
/// The scripted hub keeps the WebSocket open and ponging in every mode
/// — only the application-frame routing changes, which is exactly the
/// pathological state a dead-ish hub or a ghost peer produces.
///
/// Ported from the FA acceptance suite (/tmp/silent_hub_test.dart, the
/// dap bug report gate). Adaptations, all mechanical: no `@Skip` (this
/// package ships the fix), `package:crypto` → the `cryptography` Sha256
/// the package itself uses for agent ids, and the constructor injects the
/// package-convention 100ms `requestTimeout` so silent-hub doors fail
/// loudly inside the 3s bound (the FA original relied on a 10s default
/// that would exceed it). Scenarios and <=3s completion assertions are
/// 1:1; the two race tests additionally require the VALUE contract —
/// with a healthy hub answering once, BOTH callers must complete with
/// the answer ('errored' would mean an orphaned caller was eaten by the
/// per-caller timeout, i.e. the fan-out regressed).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

/// How the scripted hub answers application frames after the handshake.
enum HubMode {
  /// Normal answers — healthy hub.
  answering,

  /// Swallow `presence_query`/`whois`/`flush` frames: read them, answer
  /// nothing, keep the socket open. BUG 1.
  silent,

  /// Answer `presence_query` with an `error` frame. BUG 2.
  errorPresence,

  /// BUG 5 (fah_hub_client 0.2.0, FA repro): an UNSOLICITED one-agent
  /// presence broadcast is pushed BEFORE the `presence_query` answer —
  /// the startup race (own join echo / others' join events racing the
  /// first query). The answer shape follows [SilentHub.echoReplyTo].
  broadcastBeforeAnswer,
}

/// Minimal scripted DAP/1 hub: real WebSocket, real handshake, and a
/// switchable application layer. Signature checks are skipped on purpose —
/// the client under test does not require the server to verify.
class SilentHub {
  HttpServer? _server;
  HubMode mode = HubMode.answering;

  /// New-hub wire law (docs/protocol.md §presence): when true,
  /// `presence_query` answers echo the request frame id in the additive
  /// string `replyTo`; broadcasts NEVER carry it. Default false = legacy
  /// hub (no echo anywhere — answers and broadcasts indistinguishable).
  bool echoReplyTo = false;

  /// The single live client socket (broadcast injection target).
  WebSocket? _client;

  /// `presence_query` frames seen — the warm-up re-run proof.
  int presenceQueries = 0;

  String get url {
    final server = _server!;
    return 'ws://127.0.0.1:${server.port}/ws';
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = _client = await WebSocketTransformer.upgrade(request);
        ws.listen(
          (dynamic data) => unawaited(_onData(ws, data as String)),
          onDone: () {},
          onError: (Object _) {},
          cancelOnError: true,
        );
      }
    }
  }

  Future<void> _onData(WebSocket ws, String data) async {
    final Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(data) as Map).cast<String, dynamic>();
    } on FormatException {
      return;
    }
    switch (frame['op'] as String?) {
      // The handshake always answers — the client must be fully connected
      // before the application layer goes quiet.
      case 'hello':
        final pubkey = frame['pubkey'] as String;
        _reply(ws, {'op': 'welcome', 'agentId': await _agentIdFor(pubkey)});
      case 'presence_query':
        presenceQueries++;
        switch (mode) {
          case HubMode.silent:
            return; // swallowed: the bug state
          case HubMode.errorPresence:
            _reply(ws, {'op': 'error', 'code': 'boom', 'msg': 'nope'});
          case HubMode.answering:
            _reply(ws, _presenceAnswer(frame, [selfPeer]));
          case HubMode.broadcastBeforeAnswer:
            // The BUG 5 injection: the unsolicited broadcast lands
            // FIRST (never a replyTo), the real answer SECOND.
            _reply(
              ws,
              {
                'op': 'presence',
                'agents': [_peer('1111111111111111')]
              },
            );
            _reply(
              ws,
              _presenceAnswer(frame, [selfPeer, _peer('fedcba9876543210')]),
            );
        }
      case 'whois':
        if (mode == HubMode.silent) return; // swallowed: the bug state
        _reply(ws, {
          'op': 'agent_info',
          'agentId': frame['agentId'] as String,
          'pubkey': pubkey,
          'x25519': frame['x25519'] as String? ?? pubkey,
          'online': true,
        });
      default:
        return; // send/join/flush and anything else: ignored
    }
  }

  /// `agentId = hex(sha256(pubkey))[:16]` (docs/protocol.md), computed
  /// with the same cryptography-package Sha256 the client uses.
  static Future<String> _agentIdFor(String pubkeyB64) async {
    final digest = await Sha256().hash(base64Decode(pubkeyB64));
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 16);
  }

  /// The client's own roster entry as the scripted hub reports it.
  static Map<String, dynamic> get selfPeer => _peer('0011223344556677');

  static Map<String, dynamic> _peer(String agentId) => {
        'agentId': agentId,
        'pubkey': pubkey,
        'x25519': pubkey,
        'online': true,
      };

  /// `presence` answer to [query]: echoes the request id in `replyTo`
  /// only when this hub speaks the echo contract (and the query had an
  /// id — omitempty per the wire law, so old clients get no field).
  Map<String, dynamic> _presenceAnswer(
    Map<String, dynamic> query,
    List<Map<String, dynamic>> agents,
  ) =>
      {
        'op': 'presence',
        'agents': agents,
        if (echoReplyTo && query['id'] != null) 'replyTo': query['id'],
      };

  /// Pushes an UNSOLICITED one-agent presence broadcast (a join/leave
  /// push — carries NO replyTo by wire law) to the connected client.
  void pushPresence(String agentId) {
    final ws = _client;
    if (ws != null) {
      _reply(ws, {
        'op': 'presence',
        'agents': [_peer(agentId)]
      });
    }
  }

  /// Force-drops the client socket (network-drop simulation).
  Future<void> dropClient() async {
    await _client?.close();
  }

  // A syntactically valid base64 blob standing in for peer keys — the
  // silence tests never reach key use.
  static final String pubkey = base64Encode(List.filled(32, 1));

  void _reply(WebSocket ws, Map<String, dynamic> frame) =>
      ws.add(jsonEncode(frame));
}

/// The package-convention short request cap (timeout_test.dart): the fake
/// hub answers on the same event loop, so 100ms cannot fire before a
/// legitimate reply — while a swallowed door fails loudly well inside the
/// 3s watchdogs below.
final requestTimeout = Duration(milliseconds: 100);

Future<HubClient> connectTo(SilentHub hub) async {
  final client = HubClient(
    config: HubConfig(url: hub.url),
    identity: await HubIdentity.generate(),
    backoff: (int _) => const Duration(milliseconds: 5),
    requestTimeout: requestTimeout,
  );
  await client.connect();
  return client;
}

/// Races [future] against a short watchdog. Returns how it ended:
/// 'completed', 'errored' (the package finished it — the FIXED contract
/// for a silent/erroring hub), or throws with the reproduction message
/// when the future never ends (the hang — the bug behavior).
Future<String> bounded<T>(Future<T> future, Duration limit) {
  return future.then((_) => 'completed', onError: (_) => 'errored').timeout(
        limit,
        onTimeout: () => throw StateError(
          'HANG REPRODUCED: the operation never completed within $limit. '
          'Either the hub never answered, or the caller\'s completer was '
          'orphaned by a concurrent request clobbering it — the hub may '
          'have answered perfectly. The package must complete every '
          'request itself (timeout + fan-out, no single-completer '
          'clobber).',
        ),
      );
}

void main() {
  const timeout = Timeout(Duration(seconds: 15));
  const limit = Duration(seconds: 3);

  test(
    'BUG 1: silent presence_query must not hang peers() (socket alive)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.silent;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(client.peers(), limit);
      // Healthy prerequisite: the connection itself never dropped.
      expect(
        client.status().connected,
        isTrue,
        reason: 'socket must stay open (pings/pongs flow) — the hang is '
            'application-layer, not a disconnect',
      );
      expect(outcome, anyOf('completed', 'errored'));
    },
  );

  test(
    'BUG 1: silent whois must not hang sendDm() (socket alive)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.silent;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(
        client.sendDm('aabbccddeeff0011', 'hello'),
        limit,
      );
      expect(client.status().connected, isTrue);
      expect(outcome, anyOf('completed', 'errored'));
    },
  );

  test(
    'BUG 2: error-answered presence_query must not hang peers()',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.errorPresence;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      final outcome = await bounded(client.peers(), limit);
      expect(client.status().connected, isTrue);
      expect(outcome, anyOf('completed', 'errored'));
    },
  );

  test(
    'BUG 3: concurrent presenceQuery must not orphan the first caller '
    '(poller vs tool clobber — hub answers INSTANTLY)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.answering; // healthy hub, no silence at all
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      // The 15s PendingInvites poller races the tool's peer resolve:
      // both call presenceQuery(); the single _presenceCompleter field
      // means the second call orphans the first caller's completer.
      List<AgentInfo>? firstPeers;
      List<AgentInfo>? secondPeers;
      final first = client.peers().then((v) => firstPeers = v);
      final second = client.peers().then((v) => secondPeers = v);

      // Fan-out contract: a healthy hub answers once, and BOTH callers
      // get the ANSWER — 'errored' here means an orphaned caller was
      // eaten by its timeout, i.e. the clobber regression.
      expect(await bounded(second, limit), 'completed');
      expect(await bounded(first, limit), 'completed');
      expect(
        firstPeers!.map((a) => a.agentId),
        contains('0011223344556677'),
      );
      expect(
        secondPeers!.map((a) => a.agentId),
        contains('0011223344556677'),
      );
    },
  );

  test(
    'BUG 4: concurrent whois of the same target must not orphan the '
    'first caller (inbound-DM sender resolution vs sendDm)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.answering; // healthy hub, no silence at all
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      // _onMsg resolves an inbound DM's sender via whois(); a sendDm to
      // the same peer races it. _pendingWhois[target] held ONE
      // completer — the second write orphaned the first.
      const target = 'aabbccddeeff0011';
      AgentInfo? firstInfo;
      AgentInfo? secondInfo;
      final first = client.whois(target).then((v) => firstInfo = v);
      final second = client.whois(target).then((v) => secondInfo = v);

      expect(await bounded(second, limit), 'completed');
      expect(await bounded(first, limit), 'completed');
      expect(firstInfo!.agentId, target);
      expect(secondInfo!.agentId, target);
    },
  );

  test(
    'BUG 5: an unsolicited presence broadcast must not steal the '
    'pending query answer (broadcast-before-answer startup race)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.echoReplyTo = true; // new hub: answers echo the request id
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      // Steady state: one clean echoed query teaches the client that
      // this hub speaks the replyTo contract. (Until its first echo a
      // new hub is wire-indistinguishable from a legacy one — the
      // residual first-query window documented in hub_client.dart.)
      await client.presenceQuery();

      // The raced query: the hub pushes a one-agent join broadcast
      // BEFORE the real two-agent answer (FA's BUG 5 injection order).
      hub.mode = HubMode.broadcastBeforeAnswer;
      List<AgentInfo>? raced;
      await bounded(
        client.peers().then((v) => raced = v),
        limit,
      );
      expect(
        raced!.map((a) => a.agentId),
        // BOTH agents of the ANSWER. ['1111111111111111'] alone would
        // be the broadcast having stolen the waiter (0.2.0 behavior).
        ['0011223344556677', 'fedcba9876543210'],
      );
    },
  );

  test(
    'warm-up: the connect-time throwaway query arms the latch, so the '
    'first consumer query is never stolen by a join broadcast',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.echoReplyTo = true;
      // Every query gets a one-agent broadcast BEFORE its answer —
      // with the latch unarmed that broadcast steals the waiter
      // (0.2.1's residual first-query window).
      hub.mode = HubMode.broadcastBeforeAnswer;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);
      await client.welcomeEvents.first; // warm-up done, latch armed

      // A post-arm unsolicited one-agent broadcast is ignored...
      hub.pushPresence('aabbccddeeff0011');
      // ...and the user's FIRST query on this connection gets the full
      // ANSWER roster, not the broadcast's single agent.
      List<AgentInfo>? roster;
      await bounded(client.peers().then((v) => roster = v), limit);
      expect(
        roster!.map((a) => a.agentId),
        ['0011223344556677', 'fedcba9876543210'],
      );
    },
  );

  test(
    'warm-up re-runs after every welcome (reconnect re-arms an unarmed '
    'latch)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.mode = HubMode.silent; // first connection cannot arm the latch
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);
      await client.welcomeEvents.first;
      expect(hub.presenceQueries, 1); // warm-up fired; silent: unarmed
      final before = hub.presenceQueries;

      hub.mode = HubMode.answering;
      hub.echoReplyTo = true;
      await hub.dropClient();
      await client.welcomeEvents.first; // second welcome: warm-up re-runs
      expect(hub.presenceQueries, greaterThan(before)); // armed this time
    },
  );

  test(
    'broadcast-only presence with no answer must NOT feed the waiter '
    '(errored by the request cap, never completed by the push)',
    timeout: timeout,
    () async {
      final hub = SilentHub();
      await hub.start();
      hub.echoReplyTo = true;
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);
      await client.presenceQuery(); // latch: hub known to echo

      hub.mode = HubMode.silent; // the raced query gets NO answer
      final outcome = bounded(client.peers(), limit);
      hub.pushPresence('1111111111111111'); // unsolicited push, no replyTo
      expect(client.status().connected, isTrue);
      expect(await outcome, 'errored');
    },
  );

  test(
    'legacy hub: a presence answer WITHOUT replyTo still completes '
    '(pre-replyTo deployments keep working)',
    timeout: timeout,
    () async {
      final hub = SilentHub(); // echoReplyTo stays false: legacy wire
      await hub.start();
      final client = await connectTo(hub);
      addTearDown(client.disconnect);
      addTearDown(hub.stop);

      List<AgentInfo>? roster;
      await bounded(client.peers().then((v) => roster = v), limit);
      expect(roster!.map((a) => a.agentId), contains('0011223344556677'));
    },
  );
}
