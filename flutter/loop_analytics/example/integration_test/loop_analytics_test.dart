// End-to-end tests: the plugin and the native SDK on a real iOS simulator or
// Android emulator, uploading to a mock Loop server that this test runs on
// the device itself.
//
// Run from `example/`: `flutter test integration_test -d <device>`.
//
// Every test here shares one `init`, and native state (the event queue,
// identity, opt-out) is kept on disk. `flutter test` installs the app afresh,
// but other runners may not, so `setUpAll` first clears whatever a previous
// run left. The tests run in declaration order: the upload-failure test
// comes last because it leaves the uploader backing off with an event queued.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:loop_analytics/loop_analytics.dart';

const _apiKey = 'loop_pk_test';
const _batchPath = '/api/ingest/analytics/batch';

/// How long to wait for an upload that should not happen.
const _quietPeriod = Duration(seconds: 1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _MockLoopServer server;
  late LoopAnalytics analytics;

  setUpAll(() async {
    server = await _MockLoopServer.start();
    analytics = await LoopAnalytics.init(
      apiKey: _apiKey,
      options: LoopOptions(
        serverUrl: server.url,
        // Only the tests' explicit flush() calls upload.
        flushInterval: const Duration(hours: 1),
      ),
    );

    // Undo what a previous run may have left: opt-out on, events queued,
    // user properties set.
    analytics.setOptOut(false);
    await analytics.flush();
    await analytics.reset();
    server.uploads.clear();
  });

  tearDownAll(() => server.close());

  setUp(() => server.uploads.clear());

  testWidgets('tracked events reach the server in one gzip batch, intact',
      (tester) async {
    expect(LoopAnalytics.instance, same(analytics));

    final blob = String.fromCharCodes(
        List.generate(30 * 1024, (i) => 0x61 + i % 26)); // 30 KB of a–z
    final nested = <String, Object?>{
      'level1': {
        'level2': {
          'level3': [
            1,
            'two',
            true,
            {'four': 4.5},
          ],
        },
      },
      'matrix': [
        [1, 2],
        [3],
      ],
      'blob': blob,
    };

    analytics.track('Item Viewed', {'Item': 'Example', 'Price': 9.99});
    analytics.track('Item Added', nested);
    analytics.track('Checkout Started', {
      'Items': ['a', 'b'],
      'Total': 3,
    });
    await analytics.flush();

    expect(server.uploads, hasLength(1));
    final upload = server.uploads.single;
    expect(upload.method, 'POST');
    expect(upload.path, _batchPath);
    expect(upload.authorization, 'Bearer $_apiKey');
    expect(upload.contentEncoding, 'gzip');

    final events = upload.events;
    expect(events.map((e) => e['name']),
        ['Item Viewed', 'Item Added', 'Checkout Started']);
    expect(events[0]['props'], {'Item': 'Example', 'Price': 9.99});
    expect(events[1]['props'], nested);
    expect(events[2]['props'], {
      'Items': ['a', 'b'],
      'Total': 3,
    });

    final deviceId = await analytics.deviceId();
    final sessionId = await analytics.sessionId();
    expect(deviceId, isNotNull);
    expect(sessionId, isNotNull);
    for (final event in events) {
      expect(event['deviceId'], deviceId);
      expect(event['sessionId'], sessionId);
      expect(event['userProps'], isEmpty);
    }
  });

  testWidgets('a null user property removes it from later events',
      (tester) async {
    analytics.setUserProperties({'Plan': 'annual', 'X': 1});
    analytics.setUserProperties({'X': null});
    analytics.track('Plan Viewed');
    await analytics.flush();

    expect(server.uploads, hasLength(1));
    expect(server.uploads.single.events.single['userProps'], {'Plan': 'annual'});
  });

  testWidgets('reset changes the device id', (tester) async {
    final before = await analytics.deviceId();
    await analytics.reset();
    final after = await analytics.deviceId();

    expect(before, isNotNull);
    expect(after, isNotNull);
    expect(after, isNot(before));

    analytics.track('After Reset');
    await analytics.flush();
    final event = server.uploads.single.events.single;
    expect(event['deviceId'], after);
    expect(event['userProps'], isEmpty);
  });

  testWidgets('opted out: new events are dropped and nothing is uploaded',
      (tester) async {
    analytics.track('Before Opt Out');
    analytics.setOptOut(true);
    analytics.track('While Opted Out');
    await analytics.flush();
    await Future<void>.delayed(_quietPeriod);

    expect(server.uploads, isEmpty);

    // Opting back in uploads what was queued before, and only that.
    analytics.setOptOut(false);
    await analytics.flush();
    await Future<void>.delayed(_quietPeriod);

    expect(server.uploads, hasLength(1));
    expect(server.uploads.single.events.map((e) => e['name']),
        ['Before Opt Out']);
  });

  // Keep last: it leaves the uploader backing off with the event queued.
  testWidgets('after a 503 the events stay queued and a flush sends nothing',
      (tester) async {
    server.respondNextWith(503); // then 202 again

    analytics.track('Upload Retried');
    await analytics.flush();

    expect(server.uploads, hasLength(1));
    expect(server.uploads.single.status, 503);
    expect(server.uploads.single.events.map((e) => e['name']),
        ['Upload Retried']);

    // Within the 30 s backoff: nothing is sent.
    await analytics.flush();
    await Future<void>.delayed(_quietPeriod);

    expect(server.uploads, hasLength(1));
  });
}

/// One request the mock server received.
class _Upload {
  _Upload({
    required this.method,
    required this.path,
    required this.authorization,
    required this.contentEncoding,
    required this.body,
    required this.status,
  });

  final String method;
  final String path;
  final String? authorization;
  final String? contentEncoding;

  /// The raw body; decoded on demand so a malformed one fails the test that
  /// reads it rather than the server.
  final List<int> body;

  /// The status the server answered with.
  final int status;

  List<Map<String, Object?>> get events {
    final json = jsonDecode(utf8.decode(gzip.decode(body)));
    return [
      for (final event in (json as Map<String, Object?>)['events'] as List)
        event as Map<String, Object?>,
    ];
  }
}

/// A stand-in for the Loop ingest API on 127.0.0.1: records every request
/// and answers 202, or the statuses queued with [respondNextWith].
class _MockLoopServer {
  _MockLoopServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_MockLoopServer> start() async =>
      _MockLoopServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final _statuses = <int>[];

  /// Requests received, oldest first.
  final uploads = <_Upload>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  /// Answers the next request with [status] instead of 202.
  void respondNextWith(int status) => _statuses.add(status);

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = <int>[];
    await request.forEach(body.addAll);
    final status = _statuses.isEmpty ? 202 : _statuses.removeAt(0);
    // Recorded before answering, so it is in [uploads] by the time the
    // native flush (and so the Dart flush) completes.
    uploads.add(_Upload(
      method: request.method,
      path: request.uri.path,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
      contentEncoding:
          request.headers.value(HttpHeaders.contentEncodingHeader),
      body: body,
      status: status,
    ));
    request.response.statusCode = status;
    await request.response.close();
  }
}
