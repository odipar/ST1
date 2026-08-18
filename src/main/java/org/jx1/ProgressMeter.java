package org.jx1;

/**
 * The progress report the optimal parsers print: an exact percentage of the
 * parse's inner-loop steps, and a time estimate fitted to how the parse has
 * been slowing down.
 *
 * <p>The step count is exact and owes nothing to the data - position {@code
 * index} is tried against every offset from 1 to {@code clamp(index, 1,
 * offsetLimit)}, so the total is a closed form known before the first step.
 * What a step <em>costs</em> is another matter - one that finds a match does
 * more work than one that finds nothing - so the percentage measures progress,
 * not remaining time. The estimate handles time: elapsed is fitted as {@code
 * a*x + b*x^2} in the percentage, through the warm-up point, the midpoint and
 * now. The square is what makes it work on real assets: a parse that finds
 * more matches as it goes gets steadily slower, and a rate measured over any
 * window - however recent - keeps predicting the past.
 */
public final class ProgressMeter {

    /**
     * Percent of the work to finish before estimating anything, so the JIT's
     * warm-up is not counted against the rest.
     */
    private static final int WARMUP = 5;

    /**
     * Percent of history the fit needs before it says anything. A curve drawn
     * through three points a couple of percent apart is mostly noise, and a
     * confidently wrong number is worse than no number.
     */
    private static final int BASELINE = 15;

    private final boolean enabled;
    private final long total;
    private final long started;
    private final long[] tickNanos = new long[101];
    private long steps;
    private int shown = -1;

    public ProgressMeter(long total, boolean enabled) {
        this.total = total;
        this.enabled = enabled;
        this.started = System.nanoTime();
    }

    /** The parse's total steps: positions {@code skip..count-1}, each against its window. */
    public static long totalSteps(int count, int skip, int offsetLimit) {
        return stepsBefore(count, offsetLimit) - stepsBefore(skip, offsetLimit);
    }

    /** Steps spent on positions {@code 0..end-1}. */
    private static long stepsBefore(int end, int offsetLimit) {
        if (end <= 0) {
            return 0;
        }
        long ramp = Math.min(end - 1L, offsetLimit);        // 1..ramp, one more each
        long flat = Math.max(0L, end - 1L - offsetLimit);   // the rest, at the full window
        return 1 + ramp * (ramp + 1) / 2 + flat * offsetLimit;
    }

    /** Advances by one position's worth of steps and reports when the percent moves. */
    public void advance(long delta) {
        steps += delta;
        if (!enabled) {
            return;
        }
        int percent = (int) (steps * 100 / total);
        if (percent != shown) {
            shown = percent;
            long now = System.nanoTime();
            tickNanos[percent] = now;
            System.out.printf("\r[%3d%%] %-12s", percent, estimate(percent, now));
            System.out.flush();
        }
    }

    /** The 100% line with the elapsed time; call once, when the parse is done. */
    public void finish() {
        assert steps == total : "the step count is meant to be exact, not an estimate";
        if (enabled) {
            System.out.printf("\r[100%%] %-12s%n", duration(System.nanoTime() - started));
        }
    }

    /** Time left, or "" until there is enough history to say. */
    private String estimate(int percent, long now) {
        int base = WARMUP;
        while (base < percent && tickNanos[base] == 0) {
            base++;                                     // a percent the loop stepped over
        }
        int mid = (base + percent) / 2;
        while (mid > base && tickNanos[mid] == 0) {
            mid--;
        }
        if (mid <= base || mid >= percent || percent - base < BASELINE) {
            return "";                                  // too little history to fit
        }
        double half = mid - base;
        double span = percent - base;
        double untilMid = tickNanos[mid] - tickNanos[base];
        double untilNow = now - tickNanos[base];
        double square = (untilNow * half - untilMid * span) / (half * span * (span - half));
        double linear = (untilMid - square * half * half) / half;
        double whole = 100.0 - base;
        double left = linear * whole + square * whole * whole - untilNow;
        if (!(left > 0)) {
            return "";                                  // NaN, or already there
        }
        return duration((long) left) + " left";
    }

    /** Seconds, in the shortest form that stays readable, rounded not floored. */
    private static String duration(long nanos) {
        long seconds = (Math.max(0, nanos) + 500_000_000L) / 1_000_000_000L;
        return seconds < 60 ? seconds + "s"
                : String.format("%dm %02ds", seconds / 60, seconds % 60);
    }
}
