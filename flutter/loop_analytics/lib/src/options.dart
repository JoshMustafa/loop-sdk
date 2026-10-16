/// How much the plugin's Dart side logs (via `dart:developer`, name
/// `loop_analytics`). The native SDK logs on its own.
enum LoopLogLevel { none, error, warning, info, debug }

/// Configuration for [LoopAnalytics.init].
class LoopOptions {
  const LoopOptions({
    this.serverUrl,
    this.flushQueueSize = 30,
    this.flushInterval = const Duration(seconds: 30),
    this.minTimeBetweenSessions = const Duration(minutes: 5),
    this.maxQueueSize = 1000,
    this.maxBatchSize = 100,
    this.legacyDeviceId,
    this.logLevel = LoopLogLevel.warning,
  });

  /// Base URL of the Loop analytics API. Defaults to [defaultServerUrl].
  final Uri? serverUrl;

  /// Upload as soon as this many events are queued.
  final int flushQueueSize;

  /// Upload queued events at least this often while the app runs.
  final Duration flushInterval;

  /// Idle time after which the next event or resume starts a new session.
  final Duration minTimeBetweenSessions;

  /// Most events kept on disk; when full, the oldest 20 are dropped.
  final int maxQueueSize;

  /// Most events sent in one request (the server accepts up to 500).
  final int maxBatchSize;

  /// A device id to adopt on first run (e.g. the id your previous analytics
  /// SDK generated) so existing anonymous users carry over. Ignored once a
  /// device id has been stored, and after [LoopAnalytics.reset].
  final String? legacyDeviceId;

  final LoopLogLevel logLevel;

  static final Uri defaultServerUrl =
      Uri.parse('https://loop-analytics-api.fly.dev');

  Uri get resolvedServerUrl => serverUrl ?? defaultServerUrl;
}
