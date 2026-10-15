// Smoke test: the Dart facade reaches the host API on a real device.
// Task 4 of the Flutter plan adds the end-to-end scenarios.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:loop_analytics/loop_analytics.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('init completes', (WidgetTester tester) async {
    final analytics = await LoopAnalytics.init(
      apiKey: 'loop_pk_test',
      // Nothing is tracked, so nothing is sent; an unreachable server keeps
      // it that way.
      options: LoopOptions(serverUrl: Uri.parse('http://127.0.0.1:9')),
    );

    expect(LoopAnalytics.instance, same(analytics));
  });
}
