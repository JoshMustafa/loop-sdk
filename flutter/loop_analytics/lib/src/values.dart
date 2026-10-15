/// Converts event or user [properties] into values the platform channel can
/// carry, as a new map.
///
/// Strings, bools, numbers, nulls, lists and string-keyed maps pass through,
/// recursively. Null values are kept: the native SDK drops them from events
/// and treats them as "remove" in user properties. Other iterables become
/// lists, map keys become strings, a [DateTime] becomes an ISO 8601 UTC
/// string with milliseconds, and anything else is `toString()`-ed. The native
/// SDK sanitises the result further.
Map<String, Object?> normaliseProperties(Map<String, Object?>? properties) {
  if (properties == null) return <String, Object?>{};
  return {
    for (final entry in properties.entries)
      entry.key: _normaliseValue(entry.value),
  };
}

Object? _normaliseValue(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is DateTime) return _formatTimestamp(value);
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        entry.key.toString(): _normaliseValue(entry.value),
    };
  }
  if (value is Iterable) {
    return [for (final Object? element in value) _normaliseValue(element)];
  }
  return value.toString();
}

/// `2026-10-15T12:34:56.789Z`: UTC, millisecond precision.
String _formatTimestamp(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
      time.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();
