// Pigeon definition of the channel between the Dart facade and the native
// Loop SDK. Regenerate after editing (from flutter/loop_analytics):
//
//   dart run pigeon --input pigeons/messages.dart
//
// Generated type names carry a LoopAnalytics prefix so they cannot collide
// with other plugins' Pigeon output in a host app.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartPackageName: 'loop_analytics',
  dartOut: 'lib/src/messages.g.dart',
  swiftOut: 'ios/Classes/Messages.g.swift',
  swiftOptions: SwiftOptions(
    errorClassName: 'LoopAnalyticsPigeonError',
  ),
  kotlinOut: 'android/src/main/kotlin/io/loop/flutter/Messages.g.kt',
  kotlinOptions: KotlinOptions(
    package: 'io.loop.flutter',
    errorClassName: 'LoopAnalyticsPigeonError',
  ),
))

/// `LoopOptions` as sent to the native SDK. Durations are milliseconds.
class NativeOptions {
  NativeOptions({
    required this.flushQueueSize,
    required this.flushIntervalMillis,
    required this.minTimeBetweenSessionsMillis,
    required this.maxQueueSize,
    required this.maxBatchSize,
  });

  /// Base URL of the Loop analytics API; null means the native default.
  String? serverUrl;
  int flushQueueSize;
  int flushIntervalMillis;
  int minTimeBetweenSessionsMillis;
  int maxQueueSize;
  int maxBatchSize;
  String? legacyDeviceId;
}

/// The native Loop SDK, called from Dart.
@HostApi()
abstract class LoopAnalyticsHostApi {
  /// Configures Loop with [apiKey] and starts analytics with [options].
  @async
  void configure(String apiKey, NativeOptions options);

  void track(String name, Map<String?, Object?> properties);

  void setUserId(String? userId);

  /// A null value removes that property.
  void setUserProperties(Map<String?, Object?> properties);

  void setPurchaserId(String? purchaserId);

  /// Completes when the native flush finishes.
  @async
  void flush();

  /// Completes when the native reset finishes.
  @async
  void reset();

  void setOptOut(bool optOut);

  @async
  String? deviceId();

  @async
  int? sessionId();
}
