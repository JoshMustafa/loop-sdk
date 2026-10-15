package j$.time;

/**
 * A stand-in for the class D8 core-library desugaring rewrites
 * {@code java.time.Instant} to on devices below API 26. Only the members
 * the SDK touches are here.
 */
public final class Instant {
    private final long millis;
    private final boolean outOfRange;

    private Instant(long millis, boolean outOfRange) {
        this.millis = millis;
        this.outOfRange = outOfRange;
    }

    public static Instant ofEpochMilli(long millis) {
        return new Instant(millis, false);
    }

    /** An instant beyond the range of epoch milliseconds, like {@code Instant.MAX}. */
    public static Instant outOfMillisRange() {
        return new Instant(0, true);
    }

    public long toEpochMilli() {
        if (outOfRange) throw new ArithmeticException("long overflow");
        return millis;
    }

    @Override
    public String toString() {
        return outOfRange ? "+1000000000-12-31T23:59:59.999999999Z" : "desugared:" + millis;
    }
}
