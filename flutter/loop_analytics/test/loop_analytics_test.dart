import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_analytics/loop_analytics.dart';
import 'package:loop_analytics/src/loop_analytics.dart' show LoopLogSink;
import 'package:loop_analytics/src/messages.g.dart';

/// One call that reached the host API: the method name and its arguments.
typedef HostCall = (String method, List<Object?> args);

/// Records every host API call instead of crossing the platform channel.
class FakeHostApi extends LoopAnalyticsHostApi {
  final calls = <HostCall>[];

  /// When set, `configure` waits for this before completing.
  Completer<void>? configureGate;

  /// Methods that throw [error] instead of succeeding.
  final failing = <String>{};
  Object error = PlatformException(code: 'channel-error', message: 'boom');

  String? deviceIdResult = 'device-id-value';
  int? sessionIdResult = 1760000000000;

  List<String> get methods => [for (final call in calls) call.$1];

  Future<T> _record<T>(String method, List<Object?> args, T result) async {
    calls.add((method, args));
    if (failing.contains(method)) throw error;
    return result;
  }

  @override
  Future<void> configure(String apiKey, NativeOptions options) async {
    calls.add(('configure', [apiKey, options]));
    if (failing.contains('configure')) throw error;
    await configureGate?.future;
  }

  @override
  Future<void> track(String name, Map<String?, Object?> properties) =>
      _record('track', [name, properties], null);

  @override
  Future<void> setUserId(String? userId) =>
      _record('setUserId', [userId], null);

  @override
  Future<void> setUserProperties(Map<String?, Object?> properties) =>
      _record('setUserProperties', [properties], null);

  @override
  Future<void> setPurchaserId(String? purchaserId) =>
      _record('setPurchaserId', [purchaserId], null);

  @override
  Future<void> flush() => _record('flush', [], null);

  @override
  Future<void> reset() => _record('reset', [], null);

  @override
  Future<void> setOptOut(bool optOut) => _record('setOptOut', [optOut], null);

  @override
  Future<String?> deviceId() => _record('deviceId', [], deviceIdResult);

  @override
  Future<int?> sessionId() => _record('sessionId', [], sessionIdResult);
}

void main() {
  late FakeHostApi host;
  late List<(LoopLogLevel, String)> logs;
  late LoopLogSink logSink;

  setUp(() {
    host = FakeHostApi();
    logs = [];
    logSink = (level, message) => logs.add((level, message));
  });

  tearDown(LoopAnalytics.resetForTesting);

  Future<LoopAnalytics> init({
    String apiKey = 'loop_pk_test',
    LoopOptions options = const LoopOptions(),
  }) =>
      LoopAnalytics.initWithHostApi(
        apiKey: apiKey,
        options: options,
        hostApi: host,
        logSink: logSink,
      );

  /// Every host call as `[method, ...args]`, for deep comparison.
  List<List<Object?>> flatCalls() =>
      [for (final call in host.calls) [call.$1, ...call.$2]];

  /// The arguments of the only call to [method].
  List<Object?> argsOf(String method) =>
      host.calls.singleWhere((call) => call.$1 == method).$2;

  group('init', () {
    test('configures the native SDK with the key and default options',
        () async {
      final analytics = await init();

      expect(LoopAnalytics.instance, same(analytics));
      expect(host.methods, ['configure']);
      final args = argsOf('configure');
      expect(args[0], 'loop_pk_test');
      final options = args[1]! as NativeOptions;
      expect(options.serverUrl, isNull);
      expect(options.flushQueueSize, 30);
      expect(options.flushIntervalMillis, 30000);
      expect(options.minTimeBetweenSessionsMillis, 300000);
      expect(options.maxQueueSize, 1000);
      expect(options.maxBatchSize, 100);
      expect(options.legacyDeviceId, isNull);
    });

    test('converts every option, durations to milliseconds', () async {
      await init(
        options: LoopOptions(
          serverUrl: Uri.parse('https://analytics.example.test/base'),
          flushQueueSize: 5,
          flushInterval: const Duration(seconds: 12, milliseconds: 345),
          minTimeBetweenSessions: const Duration(minutes: 2),
          maxQueueSize: 250,
          maxBatchSize: 50,
          legacyDeviceId: 'legacy-device',
        ),
      );

      final options = argsOf('configure')[1]! as NativeOptions;
      expect(options.serverUrl, 'https://analytics.example.test/base');
      expect(options.flushQueueSize, 5);
      expect(options.flushIntervalMillis, 12345);
      expect(options.minTimeBetweenSessionsMillis, 120000);
      expect(options.maxQueueSize, 250);
      expect(options.maxBatchSize, 50);
      expect(options.legacyDeviceId, 'legacy-device');
    });

    test('the instance is available as soon as init is called', () {
      host.configureGate = Completer<void>();
      unawaited(init());
      expect(LoopAnalytics.instance, isNotNull);
    });

    test('calling init again returns the same instance and logs a warning',
        () async {
      final first = await init();
      final second = await init(apiKey: 'loop_pk_other');

      expect(second, same(first));
      expect(host.methods, ['configure']);
      expect(logs, hasLength(1));
      expect(logs.single.$1, LoopLogLevel.warning);
    });

    test('init called again while the first is pending waits for it',
        () async {
      host.configureGate = Completer<void>();
      final first = init();
      var secondDone = false;
      final second = init().then((analytics) {
        secondDone = true;
        return analytics;
      });

      await pumpEventQueue();
      expect(secondDone, isFalse);
      host.configureGate!.complete();

      expect(await second, same(await first));
      expect(host.methods, ['configure']);
    });

    test('a failing configure is logged and init still returns the instance',
        () async {
      host.failing.add('configure');

      final analytics = await init();

      expect(LoopAnalytics.instance, same(analytics));
      expect(logs.single.$1, LoopLogLevel.error);
      expect(logs.single.$2, contains('configure'));
    });
  });

  group('after init', () {
    late LoopAnalytics analytics;

    setUp(() async {
      analytics = await init();
      host.calls.clear();
    });

    test('track sends the name and normalised properties', () async {
      analytics.track('Purchase Completed', {
        'Plan': 'annual',
        'price': 4.99,
        'at': DateTime.utc(2026, 10, 15, 9, 30),
        'nested': {
          'list': [1, null, 'two'],
        },
        'none': null,
      });
      await pumpEventQueue();

      expect(argsOf('track'), [
        'Purchase Completed',
        {
          'Plan': 'annual',
          'price': 4.99,
          'at': '2026-10-15T09:30:00.000Z',
          'nested': {
            'list': [1, null, 'two'],
          },
          'none': null,
        },
      ]);
    });

    test('track without properties sends an empty map', () async {
      analytics.track('App Opened');
      await pumpEventQueue();

      expect(argsOf('track'), ['App Opened', <String?, Object?>{}]);
    });

    test('setUserId sends the id, or null when signed out', () async {
      analytics.setUserId('user-1');
      analytics.setUserId(null);
      await pumpEventQueue();

      expect(flatCalls(), [
        ['setUserId', 'user-1'],
        ['setUserId', null],
      ]);
    });

    test('setUserProperties passes null values through (they remove keys)',
        () async {
      analytics.setUserProperties({'Plan': 'annual', 'X': null});
      await pumpEventQueue();

      final properties = argsOf('setUserProperties')[0]! as Map;
      expect(properties, {'Plan': 'annual', 'X': null});
      expect(properties.containsKey('X'), isTrue);
    });

    test('setPurchaserId sends the id, or null to clear', () async {
      analytics.setPurchaserId(r'$RCAnonymousID:abc');
      analytics.setPurchaserId(null);
      await pumpEventQueue();

      expect(flatCalls(), [
        ['setPurchaserId', r'$RCAnonymousID:abc'],
        ['setPurchaserId', null],
      ]);
    });

    test('setOptOut sends the flag', () async {
      analytics.setOptOut(true);
      analytics.setOptOut(false);
      await pumpEventQueue();

      expect(flatCalls(), [
        ['setOptOut', true],
        ['setOptOut', false],
      ]);
    });

    test('flush and reset complete when the native call completes', () async {
      await analytics.flush();
      await analytics.reset();

      expect(host.methods, ['flush', 'reset']);
    });

    test('deviceId and sessionId return the native values', () async {
      expect(await analytics.deviceId(), 'device-id-value');
      expect(await analytics.sessionId(), 1760000000000);

      host.deviceIdResult = null;
      host.sessionIdResult = null;
      expect(await analytics.deviceId(), isNull);
      expect(await analytics.sessionId(), isNull);
    });
  });

  group('calls before init completes', () {
    test('are buffered and replayed in order after configure', () async {
      host.configureGate = Completer<void>();
      final started = init();
      final analytics = LoopAnalytics.instance!;

      analytics.track('first', {'n': 1});
      analytics.setUserId('user-1');
      analytics.setUserProperties({'Plan': 'annual'});
      analytics.setPurchaserId('purchaser-1');
      analytics.setOptOut(false);
      final flushed = analytics.flush();
      analytics.track('second');
      final deviceId = analytics.deviceId();
      final sessionId = analytics.sessionId();
      final reset = analytics.reset();
      await pumpEventQueue();

      expect(host.methods, ['configure']);

      host.configureGate!.complete();
      await started;
      await flushed;
      await reset;
      expect(await deviceId, 'device-id-value');
      expect(await sessionId, 1760000000000);

      expect(host.methods, [
        'configure',
        'track',
        'setUserId',
        'setUserProperties',
        'setPurchaserId',
        'setOptOut',
        'flush',
        'track',
        'deviceId',
        'sessionId',
        'reset',
      ]);
      expect(host.calls[1].$2, [
        'first',
        {'n': 1},
      ]);
      expect(host.calls[7].$2, ['second', <String?, Object?>{}]);
    });

    test('async calls do not complete before configure does', () async {
      host.configureGate = Completer<void>();
      unawaited(init());
      var flushed = false;
      unawaited(LoopAnalytics.instance!.flush().then((_) => flushed = true));

      await pumpEventQueue();
      expect(flushed, isFalse);

      host.configureGate!.complete();
      await pumpEventQueue();
      expect(flushed, isTrue);
    });

    test('properties are captured when the call is made, not when replayed',
        () async {
      host.configureGate = Completer<void>();
      final started = init();
      final properties = <String, Object?>{'n': 1};
      LoopAnalytics.instance!.track('event', properties);
      properties['n'] = 2;

      host.configureGate!.complete();
      await started;
      await pumpEventQueue();

      expect(argsOf('track'), [
        'event',
        {'n': 1},
      ]);
    });

    test('are still replayed when configure fails', () async {
      host.failing.add('configure');
      final started = init();
      LoopAnalytics.instance!.track('event');

      await started;
      await pumpEventQueue();

      expect(host.methods, ['configure', 'track']);
    });

    test('keep the newest 1000 calls, dropping the oldest with one log line',
        () async {
      host.configureGate = Completer<void>();
      final started = init();
      final analytics = LoopAnalytics.instance!;

      final dropped = analytics.deviceId();
      for (var i = 0; i < 1005; i++) {
        analytics.track('event $i');
      }

      host.configureGate!.complete();
      await started;
      await pumpEventQueue();

      expect(await dropped, isNull);
      final tracked = [
        for (final call in host.calls)
          if (call.$1 == 'track') call.$2[0],
      ];
      expect(tracked, hasLength(1000));
      expect(tracked.first, 'event 5');
      expect(tracked.last, 'event 1004');
      expect(host.methods, isNot(contains('deviceId')));
      expect(logs, hasLength(1));
      expect(logs.single.$1, LoopLogLevel.warning);
    });
  });

  group('errors', () {
    late LoopAnalytics analytics;

    setUp(() async {
      analytics = await init();
      host.calls.clear();
    });

    test('fire-and-forget failures are logged, never thrown', () async {
      host.failing.addAll([
        'track',
        'setUserId',
        'setUserProperties',
        'setPurchaserId',
        'setOptOut',
      ]);

      analytics.track('event', {'secret': 'property-value'});
      analytics.setUserId('user-id-value');
      analytics.setUserProperties({'Plan': 'property-value'});
      analytics.setPurchaserId('purchaser-id-value');
      analytics.setOptOut(true);
      await pumpEventQueue();

      expect(logs.map((log) => log.$1), everyElement(LoopLogLevel.error));
      expect(logs.map((log) => log.$2), [
        contains('track'),
        contains('setUserId'),
        contains('setUserProperties'),
        contains('setPurchaserId'),
        contains('setOptOut'),
      ]);
    });

    test('awaited calls complete normally when the channel fails', () async {
      host.error = MissingPluginException('no plugin');
      host.failing.addAll(['flush', 'reset', 'deviceId', 'sessionId']);

      await analytics.flush();
      await analytics.reset();
      expect(await analytics.deviceId(), isNull);
      expect(await analytics.sessionId(), isNull);

      expect(logs.map((log) => log.$2), [
        contains('flush'),
        contains('reset'),
        contains('deviceId'),
        contains('sessionId'),
      ]);
    });

    test('logs never contain values, ids or exception messages', () async {
      host.failing.addAll(['track', 'setUserId', 'setPurchaserId']);
      host.error = PlatformException(
          code: 'channel-error', message: 'detail user-id-value');

      analytics.track('event', {'secret': 'property-value'});
      analytics.setUserId('user-id-value');
      analytics.setPurchaserId('purchaser-id-value');
      await pumpEventQueue();

      expect(logs, hasLength(3));
      for (final (_, message) in logs) {
        expect(message, isNot(contains('property-value')));
        expect(message, isNot(contains('user-id-value')));
        expect(message, isNot(contains('purchaser-id-value')));
      }
    });

    test('a value whose toString throws drops the call and logs', () async {
      analytics.track('event', {'bad': _ThrowingToString()});
      await pumpEventQueue();

      expect(host.methods, isEmpty);
      expect(logs.single.$1, LoopLogLevel.error);
      expect(logs.single.$2, contains('track'));
    });
  });

  group('logLevel', () {
    test('none silences the SDK', () async {
      host.failing.add('track');
      final analytics =
          await init(options: const LoopOptions(logLevel: LoopLogLevel.none));

      analytics.track('event');
      await init();
      await pumpEventQueue();

      expect(logs, isEmpty);
    });

    test('error hides warnings but keeps errors', () async {
      host.failing.add('track');
      final analytics =
          await init(options: const LoopOptions(logLevel: LoopLogLevel.error));

      await init();
      analytics.track('event');
      await pumpEventQueue();

      expect(logs.map((log) => log.$1), [LoopLogLevel.error]);
    });
  });
}

class _ThrowingToString {
  @override
  String toString() => throw StateError('no');
}
