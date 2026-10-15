import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'messages.g.dart';
import 'options.dart';
import 'values.dart';

/// Where the facade's log lines go. Messages never contain property values
/// or ids.
typedef LoopLogSink = void Function(LoopLogLevel level, String message);

/// A call made before [LoopAnalytics.init] completed, waiting to be sent.
typedef _PendingCall = ({void Function() send, void Function() drop});

/// Product analytics for Loop.
///
/// Create it once with [init], then call [track] and friends from anywhere
/// (or through [instance]). Every call is safe to make synchronously and
/// none of them throws into the host app: problems are logged instead.
///
/// The work is done by the native Loop SDK on iOS and Android; this class
/// forwards each call to it. Calls made before [init] completes are kept in
/// order and sent once the native SDK is configured.
class LoopAnalytics {
  LoopAnalytics._(this._api, this._logLevel, this._logSink);

  /// Server limit on one event's JSON encoding. The native SDK drops larger
  /// events.
  static const maxEventBytes = 32 * 1024;

  /// Most calls kept while [init] is in progress; beyond it the oldest are
  /// dropped.
  static const _maxPendingCalls = 1000;

  /// Longest wait for the native configure before [init] completes anyway,
  /// so a missing native reply never blocks app launch.
  static const _configureTimeout = Duration(seconds: 10);

  static LoopAnalytics? _instance;
  static Future<LoopAnalytics>? _started;

  /// The instance, or null before [init] is called. It accepts calls as soon
  /// as [init] has been called, even before it completes.
  static LoopAnalytics? get instance => _instance;

  /// Sets up the SDK: configures the native Loop SDK with [apiKey] and starts
  /// analytics with [options]. Calling it again returns the same instance.
  ///
  /// Completes once the native SDK is configured, or after 10 seconds if it
  /// has not replied (logged); either way, calls made meanwhile are sent.
  static Future<LoopAnalytics> init({
    required String apiKey,
    LoopOptions options = const LoopOptions(),
  }) {
    try {
      // The platform channel needs the binary messenger, and apps often
      // call init before runApp.
      WidgetsFlutterBinding.ensureInitialized();
    } catch (_) {
      // The channel call fails instead and is logged.
    }
    return _init(apiKey, options, LoopAnalyticsHostApi(), _developerLogSink,
        _configureTimeout);
  }

  /// [init] with an injected host API, log sink and configure timeout (for
  /// tests).
  @visibleForTesting
  static Future<LoopAnalytics> initWithHostApi({
    required String apiKey,
    LoopOptions options = const LoopOptions(),
    required LoopAnalyticsHostApi hostApi,
    LoopLogSink? logSink,
    Duration configureTimeout = _configureTimeout,
  }) =>
      _init(apiKey, options, hostApi, logSink ?? _developerLogSink,
          configureTimeout);

  /// Forgets the instance so the next [init] creates a new one (for tests).
  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
    _started = null;
  }

  static Future<LoopAnalytics> _init(
    String apiKey,
    LoopOptions options,
    LoopAnalyticsHostApi api,
    LoopLogSink logSink,
    Duration configureTimeout,
  ) {
    final existing = _instance;
    if (existing != null) {
      existing._log(
          LoopLogLevel.warning, 'LoopAnalytics.init called again; ignoring');
      return _started!;
    }
    final analytics = LoopAnalytics._(api, options.logLevel, logSink);
    _instance = analytics;
    return _started =
        analytics._configure(apiKey, options, configureTimeout);
  }

  final LoopAnalyticsHostApi _api;
  final LoopLogLevel _logLevel;
  final LoopLogSink _logSink;

  /// False until the native SDK has been configured; calls wait in
  /// [_pending] until then.
  bool _configured = false;
  final _pending = ListQueue<_PendingCall>();
  bool _loggedPendingOverflow = false;

  Future<LoopAnalytics> _configure(
    String apiKey,
    LoopOptions options,
    Duration timeout,
  ) async {
    await _call(
      'configure',
      () => _api.configure(apiKey, _native(options)).timeout(timeout),
    );
    // Even if configure failed: the native SDK then ignores the calls.
    while (_pending.isNotEmpty) {
      _pending.removeFirst().send();
    }
    _configured = true;
    return this;
  }

  static NativeOptions _native(LoopOptions options) => NativeOptions(
        serverUrl: options.serverUrl?.toString(),
        flushQueueSize: options.flushQueueSize,
        flushIntervalMillis: options.flushInterval.inMilliseconds,
        minTimeBetweenSessionsMillis:
            options.minTimeBetweenSessions.inMilliseconds,
        maxQueueSize: options.maxQueueSize,
        maxBatchSize: options.maxBatchSize,
        legacyDeviceId: options.legacyDeviceId,
      );

  /// Records an event. [properties] may hold any JSON values (lists and
  /// nested maps included); null values are dropped and anything else is
  /// stringified. The event is queued on disk and uploaded in the background.
  void track(String name, [Map<String, Object?>? properties]) {
    _guard('track', () {
      final props = normaliseProperties(properties);
      _send('track', () => _api.track(name, props));
    });
  }

  /// Sets the signed-in user's id; null (or empty) means signed out.
  void setUserId(String? userId) {
    _send('setUserId', () => _api.setUserId(userId));
  }

  /// Merges [properties] into the user-property snapshot sent with every
  /// event. A null value removes that property.
  void setUserProperties(Map<String, Object?> properties) {
    _guard('setUserProperties', () {
      final props = normaliseProperties(properties);
      _send('setUserProperties', () => _api.setUserProperties(props));
    });
  }

  /// Sets the RevenueCat app user id (may be `$RCAnonymousID:…`); null clears.
  void setPurchaserId(String? purchaserId) {
    _send('setPurchaserId', () => _api.setPurchaserId(purchaserId));
  }

  /// Uploads queued events now. Completes when the queue is empty or an
  /// upload failed (events stay queued and are retried with backoff; a
  /// flush during backoff returns at once and sends nothing).
  Future<void> flush() => _request('flush', _api.flush);

  /// Forgets the current person: a new random device id, no user id, user
  /// properties or purchaser id, and a new session. Already-queued events
  /// keep the identity they were tracked with. Opt-out is kept.
  Future<void> reset() => _request('reset', _api.reset);

  /// When true, new events are dropped and nothing is uploaded until it is
  /// set back to false. Events already queued are kept (and uploaded after
  /// opting back in). Persisted across launches.
  void setOptOut(bool optOut) {
    _send('setOptOut', () => _api.setOptOut(optOut));
  }

  /// The id events are attributed to when no user is signed in; null if the
  /// native SDK has not started.
  ///
  /// Asynchronous because it is read from the native SDK (it was a getter
  /// in the pure-Dart SDK).
  Future<String?> deviceId() => _request<String?>('deviceId', _api.deviceId);

  /// The current session's start time in ms since epoch; null if the native
  /// SDK has not started.
  ///
  /// Asynchronous because it is read from the native SDK (it was a getter
  /// in the pure-Dart SDK).
  Future<int?> sessionId() => _request<int?>('sessionId', _api.sessionId);

  /// Sends a fire-and-forget call now, or once configured.
  void _send(String what, Future<void> Function() call) {
    void send() => unawaited(_call(what, call));
    if (_configured) {
      send();
    } else {
      _enqueue((send: send, drop: () {}));
    }
  }

  /// Sends a call whose result the caller awaits, now or once configured.
  /// Completes with null if the call fails or is dropped.
  Future<T?> _request<T>(String what, Future<T> Function() call) {
    if (_configured) return _call(what, call);
    final result = Completer<T?>();
    _enqueue((
      send: () => result.complete(_call(what, call)),
      drop: () => result.complete(null),
    ));
    return result.future;
  }

  void _enqueue(_PendingCall call) {
    if (_pending.length >= _maxPendingCalls) {
      _pending.removeFirst().drop();
      if (!_loggedPendingOverflow) {
        _loggedPendingOverflow = true;
        _log(
            LoopLogLevel.warning,
            'More than $_maxPendingCalls calls before init completed; '
            'dropping the oldest');
      }
    }
    _pending.add(call);
  }

  /// Runs a host API call; a failure is logged and gives null.
  Future<T?> _call<T>(String what, Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      _log(LoopLogLevel.error, '$what failed (${_describe(e)})');
      return null;
    }
  }

  void _guard(String what, void Function() body) {
    try {
      body();
    } catch (e) {
      _log(LoopLogLevel.error, '$what failed (${_describe(e)})');
    }
  }

  /// The error's kind, without its message (which may hold values or ids).
  static String _describe(Object error) => switch (error) {
        PlatformException(:final code) => 'PlatformException $code',
        _ => error.runtimeType.toString(),
      };

  void _log(LoopLogLevel level, String message) {
    if (_logLevel == LoopLogLevel.none || level.index > _logLevel.index) {
      return;
    }
    try {
      _logSink(level, message);
    } catch (_) {
      // Logging must never break the host app.
    }
  }
}

void _developerLogSink(LoopLogLevel level, String message) {
  developer.log(
    message,
    name: 'loop_analytics',
    level: switch (level) {
      LoopLogLevel.error => 1000,
      LoopLogLevel.warning => 900,
      LoopLogLevel.info => 800,
      _ => 500,
    },
  );
}
