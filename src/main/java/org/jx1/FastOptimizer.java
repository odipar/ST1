package org.jx1;

/**
 * {@link Optimizer}, restructured to not allocate: the same parse, found the
 * same way, producing byte-identical output - so {@code compat.py}'s
 * byte-for-byte comparison against the original C compressor holds for this
 * class exactly as it did for the original.
 *
 * <p>The original materialises every candidate as a {@link Block}, and nearly
 * all of them lose and become garbage - gigabytes of allocation per packed
 * asset. This version runs the identical DP forward on primitive arrays,
 * recording per position the winning cost and a three-int descriptor of the
 * winning candidate, then builds only the blocks the winning chain actually
 * contains by replaying each recorded decision backward from the descriptors,
 * the winning costs and the data itself. Candidates are evaluated in the same
 * order with the same strictly-better replacement rule, so ties fall exactly
 * as in the original. {@link Optimizer} stays in the tree as the specification
 * this class is checked against. It has a twin in the ST4 repository
 * (odipar/ST4, {@code St4FastOptimizer}) that differs only in the cost model:
 * one flag bit before an offset rather than three control bits, the byte form
 * reaching 128 rather than 512, and no {@code skip} parameter shifting where
 * the parse starts and where the fake block sits.
 */
public final class FastOptimizer {

    public static final int INITIAL_OFFSET = Optimizer.INITIAL_OFFSET;

    private static final int NONE = Integer.MIN_VALUE;

    private final byte[] input;
    private final int skip;
    private final int offsetLimit;

    /** Per position: the winning cost, and the descriptor to rebuild it. */
    private final int[] optimalBits;
    private final byte[] winKind;
    private final int[] winOffset;
    private final int[] winAux;

    private FastOptimizer(byte[] input, int skip, int offsetLimit) {
        this.input = input;
        this.skip = skip;
        this.offsetLimit = offsetLimit;
        this.optimalBits = new int[input.length];
        this.winKind = new byte[input.length];
        this.winOffset = new int[input.length];
        this.winAux = new int[input.length];
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input},
     * reporting progress on stdout while it works.
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit) {
        return optimize(input, skip, offsetLimit, true);
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input} -
     * the same chain {@link Optimizer#optimize} returns, byte for byte.
     *
     * @param progress whether to report on stdout, as {@link ProgressMeter}
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit,
                                 boolean progress) {
        var optimizer = new FastOptimizer(input, skip, offsetLimit);
        optimizer.forward(progress);
        return new ChainRebuilder(input, skip, optimizer.optimalBits,
                optimizer.winKind, optimizer.winOffset, optimizer.winAux).rebuild();
    }

    /**
     * The winning cost per position, for the tests that hold other optimizers
     * to this one: the optimum is unique, so any exact optimizer must produce
     * this exact array.
     */
    static int[] costs(byte[] input, int skip, int offsetLimit) {
        var optimizer = new FastOptimizer(input, skip, offsetLimit);
        optimizer.forward(false);
        return optimizer.optimalBits;
    }

    private static int eliasGammaBits(int value) {
        return 2 * (31 - Integer.numberOfLeadingZeros(value)) + 1;
    }

    // ------------------------------------------------------------- forward

    /**
     * The DP of {@link Optimizer#optimize}, candidate for candidate, on
     * primitives; see {@code St4FastOptimizer.forward} for the shape.
     */
    private void forward(boolean progress) {
        int count = input.length;
        int width = (int) Math.clamp(count - 1L, INITIAL_OFFSET, offsetLimit);
        int[] stateBits = new int[width + 1];
        int[] stateEnd = new int[width + 1];
        int[] litBits = new int[width + 1];
        int[] litEnd = new int[width + 1];
        int[] matchLength = new int[width + 1];
        java.util.Arrays.fill(stateEnd, NONE);
        java.util.Arrays.fill(litEnd, NONE);
        int[] bestLength = new int[Math.max(count, 3)];
        bestLength[2] = 2;

        // The fake block every chain hangs from, ending just before the start.
        stateBits[INITIAL_OFFSET] = -1;
        stateEnd[INITIAL_OFFSET] = skip - 1;

        var meter = new ProgressMeter(
                ProgressMeter.totalSteps(count, skip, offsetLimit), progress);

        for (int index = skip; index < count; index++) {
            int maxOffset = (int) Math.clamp((long) index, INITIAL_OFFSET, offsetLimit);
            int bestLengthSize = 2;
            byte value = input[index];
            int best = Integer.MAX_VALUE;
            for (int offset = 1; offset <= maxOffset; offset++) {
                if (index != skip && index >= offset && value == input[index - offset]) {
                    // Copy from last offset, after a literal run.
                    if (litEnd[offset] != NONE) {
                        int bits = litBits[offset] + 1
                                + eliasGammaBits(index - litEnd[offset]);
                        stateBits[offset] = bits;
                        stateEnd[offset] = index;
                        if (bits < best) {
                            best = bits;
                            winKind[index] = ChainRebuilder.REP;
                            winOffset[index] = offset;
                            winAux[index] = litEnd[offset];
                        }
                    }
                    // Copy from a new offset, at the best split length.
                    if (++matchLength[offset] > 1) {
                        if (bestLengthSize < matchLength[offset]) {
                            int bits = optimalBits[index - bestLength[bestLengthSize]]
                                    + eliasGammaBits(bestLength[bestLengthSize] - 1);
                            do {
                                bestLengthSize++;
                                int shorterBits = optimalBits[index - bestLengthSize]
                                        + eliasGammaBits(bestLengthSize - 1);
                                if (shorterBits <= bits) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = shorterBits;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < matchLength[offset]);
                        }
                        int length = bestLength[matchLength[offset]];
                        int bits = optimalBits[index - length] + 1
                                + (offset > 128 ? 16 : 8)
                                + eliasGammaBits(length - 1);
                        if (stateEnd[offset] != index || stateBits[offset] > bits) {
                            stateBits[offset] = bits;
                            stateEnd[offset] = index;
                            if (bits < best) {
                                best = bits;
                                winKind[index] = ChainRebuilder.NEW;
                                winOffset[index] = offset;
                                winAux[index] = length;
                            }
                        }
                    }
                } else {
                    // Literals, continuing from the offset's last match.
                    matchLength[offset] = 0;
                    if (stateEnd[offset] != NONE) {
                        int length = index - stateEnd[offset];
                        int bits = stateBits[offset] + 1 + eliasGammaBits(length)
                                + length * 8;
                        litBits[offset] = bits;
                        litEnd[offset] = index;
                        if (bits < best) {
                            best = bits;
                            winKind[index] = ChainRebuilder.LITERALS;
                            winOffset[index] = offset;
                            winAux[index] = stateEnd[offset];
                        }
                    }
                }
            }
            assert best != Integer.MAX_VALUE : "every position has a winner";
            optimalBits[index] = best;
            meter.advance(maxOffset);
        }
        meter.finish();
    }
}
