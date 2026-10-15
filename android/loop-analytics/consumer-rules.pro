# loop-analytics' only reflection: Sanitize recognises java.time.Instant and
# its desugared twin j$.time.Instant by class name and calls their public
# toEpochMilli(). java.time is part of the platform, so R8 leaves it alone;
# if shrinking removes j$.time.Instant.toEpochMilli() from an app that never
# calls it, such values fall back to Instant.toString() (also ISO 8601).
# Nothing in loop-analytics itself needs keeping.
