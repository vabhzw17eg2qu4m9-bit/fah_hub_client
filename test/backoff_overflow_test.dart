import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

/// Regression: after 64 failed reconnects, `1 << (attempt - 1)` overflows
/// 64-bit int semantics — attempt 64 is NEGATIVE and attempt 65+ is ZERO —
/// so `seconds > 30` never triggers and `Duration.zero` turns the reconnect
/// loop into a tight spin that burns a full core forever (observed live:
/// `_reconnectAttempt` at 69,730,601 with the process at ~90% CPU).
void main() {
  group('HubClient.defaultBackoff overflow', () {
    test('grows exponentially below the cap', () {
      expect(HubClient.defaultBackoff(1), const Duration(seconds: 1));
      expect(HubClient.defaultBackoff(2), const Duration(seconds: 2));
      expect(HubClient.defaultBackoff(5), const Duration(seconds: 16));
      expect(HubClient.defaultBackoff(6), const Duration(seconds: 30));
    });

    test('the cap survives shift overflow at attempt 64+', () {
      expect(HubClient.defaultBackoff(63), const Duration(seconds: 30));
      expect(HubClient.defaultBackoff(64), const Duration(seconds: 30));
      expect(HubClient.defaultBackoff(65), const Duration(seconds: 30));
      expect(HubClient.defaultBackoff(1000), const Duration(seconds: 30));
      expect(
        HubClient.defaultBackoff(69730601),
        const Duration(seconds: 30),
      );
    });
  });
}
