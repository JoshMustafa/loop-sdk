import 'package:flutter_test/flutter_test.dart';

import 'package:loop_analytics_example/main.dart';

void main() {
  testWidgets('shows the example title', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Loop Analytics example'), findsOneWidget);
  });
}
