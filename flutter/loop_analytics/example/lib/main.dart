import 'package:flutter/material.dart';

// Placeholder app: Task 4 of the Flutter plan replaces it with the real
// example that calls LoopAnalytics.
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: const Center(
          child: Text('Loop Analytics example'),
        ),
      ),
    );
  }
}
