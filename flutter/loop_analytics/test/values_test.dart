import 'package:flutter_test/flutter_test.dart';
import 'package:loop_analytics/src/values.dart';

enum _Plan { annual }

class _Thing {
  @override
  String toString() => 'thing';
}

void main() {
  group('normaliseProperties', () {
    test('null properties become an empty map', () {
      expect(normaliseProperties(null), <String, Object?>{});
    });

    test('JSON primitives pass through unchanged', () {
      final out = normaliseProperties({
        'string': 'a',
        'int': 42,
        'double': 1.5,
        'bool': true,
        'null': null,
      });
      expect(out, {
        'string': 'a',
        'int': 42,
        'double': 1.5,
        'bool': true,
        'null': null,
      });
    });

    test('null values are kept so setUserProperties can remove keys', () {
      final out = normaliseProperties({'Plan': 'annual', 'X': null});
      expect(out.containsKey('X'), isTrue);
      expect(out['X'], isNull);
    });

    test('a DateTime becomes an ISO 8601 UTC string with milliseconds', () {
      final utc = DateTime.utc(2026, 10, 15, 12, 34, 56, 789, 999);
      final local = utc.toLocal();
      final whole = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(normaliseProperties({'utc': utc, 'local': local, 'whole': whole}),
          {
            'utc': '2026-10-15T12:34:56.789Z',
            'local': '2026-10-15T12:34:56.789Z',
            'whole': '2026-01-02T03:04:05.000Z',
          });
    });

    test('unknown values become their toString()', () {
      expect(
        normaliseProperties({'thing': _Thing(), 'plan': _Plan.annual}),
        {'thing': 'thing', 'plan': '_Plan.annual'},
      );
    });

    test('non-finite doubles pass through for the native side to handle', () {
      final out = normaliseProperties({'nan': double.nan, 'inf': double.infinity});
      expect((out['nan']! as double).isNaN, isTrue);
      expect(out['inf'], double.infinity);
    });

    test('lists and maps are normalised recursively, several levels deep', () {
      final when = DateTime.utc(2026, 10, 15);
      final out = normaliseProperties({
        'list': [
          1,
          null,
          when,
          [
            'a',
            {'deep': when, 'none': null},
          ],
        ],
        'map': {
          'level2': {
            'level3': {
              'level4': [_Thing(), when],
            },
          },
        },
      });
      expect(out, {
        'list': [
          1,
          null,
          '2026-10-15T00:00:00.000Z',
          [
            'a',
            {'deep': '2026-10-15T00:00:00.000Z', 'none': null},
          ],
        ],
        'map': {
          'level2': {
            'level3': {
              'level4': ['thing', '2026-10-15T00:00:00.000Z'],
            },
          },
        },
      });
    });

    test('nested map keys become strings', () {
      expect(
        normaliseProperties({
          'map': {1: 'one', _Plan.annual: 'plan', null: 'nothing'},
        }),
        {
          'map': {'1': 'one', '_Plan.annual': 'plan', 'null': 'nothing'},
        },
      );
    });

    test('other iterables become lists', () {
      expect(
        normaliseProperties({
          'set': {'a', 'b'},
          'iterable': [1, 2].map((n) => n * 10),
        }),
        {
          'set': ['a', 'b'],
          'iterable': [10, 20],
        },
      );
    });

    test('a 30 KB string passes through intact', () {
      final big = 'x' * (30 * 1024);
      expect(normaliseProperties({'big': big})['big'], big);
    });

    test('the result is a copy: later changes to the input do not leak in',
        () {
      final nested = <String, Object?>{'a': 1};
      final input = <String, Object?>{'nested': nested};
      final out = normaliseProperties(input);
      nested['a'] = 2;
      input['added'] = true;
      expect(out, {
        'nested': {'a': 1},
      });
    });
  });
}
