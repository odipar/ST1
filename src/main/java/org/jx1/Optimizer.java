package org.jx1;

import org.jspecify.annotations.Nullable;

/**
 * Optimal LZ parser for the ZX1 format. Java port of {@code optimize.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Optimizer {

    public static final int INITIAL_OFFSET = 1;

    private Optimizer() {}

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



    /**
     * Time left, or "" until there is enough history to say.
     *
     * <p>Elapsed time is fitted as {@code a*x + b*x^2} in the percentage x,
     * through the warm-up point, the midpoint and now. The square is what makes
     * it work on real assets: a step costs what its neighbourhood costs, so a
     * parse that finds more matches as it goes gets steadily slower, and a rate
     * measured over any window - however recent - keeps predicting the past. On
     * an asset whose cost per step is flat, {@code b} comes out near zero and
     * this is the straight-line estimate it should be.
     */
    private static String estimate(int percent, long now, long[] tickNanos) {
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

    /**
     * Inner-loop steps a parse of positions {@code skip..length-1} will take.
     *
     * <p>The COUNT is exact and owes nothing to the data: position {@code
     * index} is tried against every offset from 1 to {@code clamp(index, 1,
     * offsetLimit)}. What the steps cost is another matter entirely - one that
     * finds a match allocates a block and walks the best-length ladder, one
     * that finds nothing does neither - so this measures the parse's progress,
     * not its remaining time. The time comes from {@link #estimate} instead.
     *
     * <p>Positions are also not equal work: the early ones try a handful of
     * offsets and the later ones the whole window, which is why counting
     * positions rather than steps would run fast and then crawl.
     */
    private static long totalSteps(int length, int skip, int offsetLimit) {
        return stepsBefore(length, offsetLimit) - stepsBefore(skip, offsetLimit);
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

    private static int offsetCeiling(int index, int offsetLimit) {
        return Math.clamp(index, INITIAL_OFFSET, offsetLimit);
    }

    private static int eliasGammaBits(int value) {
        int bits = 1;
        while ((value >>= 1) != 0) {
            bits += 2;
        }
        return bits;
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input},
     * reporting progress on stdout while it works.
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit) {
        return optimize(input, skip, offsetLimit, true);
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input}.
     *
     * <p>This is the slow half of packing - every position against every offset
     * - so it reports as it goes. Callers that are not a person waiting at a
     * terminal pass {@code false}.
     *
     * @param progress whether to report on stdout: a percentage of the parse's
     *                 steps, which is exact, and a time estimate fitted to
     *                 how the parse has been slowing down, which is not
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit,
                                 boolean progress) {
        int maxOffset = offsetCeiling(input.length - 1, offsetLimit);
        var lastLiteral = new @Nullable Block[maxOffset + 1];
        var lastMatch = new @Nullable Block[maxOffset + 1];
        var optimal = new @Nullable Block[input.length];
        int[] matchLength = new int[maxOffset + 1];
        int[] bestLength = new int[Math.max(input.length, 3)];
        bestLength[2] = 2;

        // Start with a fake block for the first real block to chain from.
        lastMatch[INITIAL_OFFSET] = new Block(-1, skip - 1, INITIAL_OFFSET, null);

        long steps = 0;
        long total = totalSteps(input.length, skip, offsetLimit);
        long started = System.nanoTime();
        long[] tickNanos = new long[101];
        int shown = -1;

        // Process remaining bytes.
        for (int index = skip; index < input.length; index++) {
            int bestLengthSize = 2;
            maxOffset = offsetCeiling(index, offsetLimit);
            for (int offset = 1; offset <= maxOffset; offset++) {
                if (index != skip && index >= offset && input[index] == input[index - offset]) {
                    // Copy from last offset.
                    Block literal = lastLiteral[offset];
                    if (literal != null) {
                        int length = index - literal.index();
                        int bits = literal.bits() + 1 + eliasGammaBits(length);
                        Block match = new Block(bits, index, offset, literal);
                        lastMatch[offset] = match;
                        optimal[index] = better(optimal[index], match);
                    }
                    // Copy from new offset.
                    if (++matchLength[offset] > 1) {
                        if (bestLengthSize < matchLength[offset]) {
                            Block best = optimal[index - bestLength[bestLengthSize]];
                            assert best != null;
                            int bits = best.bits() + eliasGammaBits(bestLength[bestLengthSize] - 1);
                            do {
                                bestLengthSize++;
                                Block shorter = optimal[index - bestLengthSize];
                                assert shorter != null;
                                int bits2 = shorter.bits() + eliasGammaBits(bestLengthSize - 1);
                                if (bits2 <= bits) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = bits2;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < matchLength[offset]);
                        }
                        int length = bestLength[matchLength[offset]];
                        Block previous = optimal[index - length];
                        assert previous != null;
                        int bits = previous.bits() + 1 + (offset > 128 ? 16 : 8) + eliasGammaBits(length - 1);
                        Block match = lastMatch[offset];
                        if (match == null || match.index() != index || match.bits() > bits) {
                            match = new Block(bits, index, offset, previous);
                            lastMatch[offset] = match;
                            optimal[index] = better(optimal[index], match);
                        }
                    }
                } else {
                    // Copy literals.
                    matchLength[offset] = 0;
                    Block match = lastMatch[offset];
                    if (match != null) {
                        int length = index - match.index();
                        int bits = match.bits() + 1 + eliasGammaBits(length) + length * 8;
                        Block literal = new Block(bits, index, 0, match);
                        lastLiteral[offset] = literal;
                        optimal[index] = better(optimal[index], literal);
                    }
                }
            }

            // Indicate progress, as a share of the work rather than of the input.
            steps += maxOffset;
            if (progress) {
                int percent = (int) (steps * 100 / total);
                if (percent != shown) {
                    shown = percent;
                    long now = System.nanoTime();
                    tickNanos[percent] = now;
                    System.out.printf("\r[%3d%%] %-12s", percent,
                            estimate(percent, now, tickNanos));
                    System.out.flush();
                }
            }
        }

        assert steps == total : "the step count is meant to be exact, not an estimate";
        if (progress) {
            System.out.printf("\r[100%%] %-12s%n", duration(System.nanoTime() - started));
        }

        Block last = optimal[input.length - 1];
        assert last != null;
        return last;
    }

    private static Block better(@Nullable Block current, Block candidate) {
        return current == null || current.bits() > candidate.bits() ? candidate : current;
    }
}
