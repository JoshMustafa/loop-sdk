import 'package:flutter/material.dart';
import 'package:loop_analytics/loop_analytics.dart';

/// Your project's public API key, e.g.
/// `flutter run --dart-define=LOOP_API_KEY=loop_pk_...`.
const _apiKey = String.fromEnvironment('LOOP_API_KEY');

void main() {
  // No need to await: calls made before init completes are kept and sent.
  LoopAnalytics.init(apiKey: _apiKey);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Loop Analytics example')),
        body: Center(
          child: ElevatedButton(
            onPressed: () => LoopAnalytics.instance
                ?.track('Item Viewed', {'Item': 'Example'}),
            child: const Text('Track Item Viewed'),
          ),
        ),
      ),
    );
  }
}
