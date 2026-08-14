package org.jx1;

import org.jspecify.annotations.Nullable;

/**
 * Optimal LZ parser for the ZX1 format. Java port of {@code optimize.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Optimizer {

    public static final int INITIAL_OFFSET = 1;

    private static final int MAX_SCALE = 50;

    private Optimizer() {}

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

    /** Returns the last block of the optimal parse chain for {@code input}. */
    public static Block optimize(byte[] input, int skip, int offsetLimit) {
        return optimize(input, skip, offsetLimit, Integer.MAX_VALUE);
    }

    /**
     * As {@link #optimize(byte[], int, int)}, but no single literal run or match
     * may exceed {@code maxOpLength} bytes.
     *
     * <p>The 68000 decoders hold an operation's remaining length in a word, so a
     * stream containing a longer operation decodes to the wrong length on them
     * while remaining perfectly valid here. Passing 65535 confines the parse to
     * what they can represent. The constraint is applied inside the search, so
     * the result is still the optimal parse <em>subject to</em> the limit, not a
     * post-hoc split of an unconstrained one.
     *
     * @throws IllegalArgumentException if no parse satisfies the limit, which
     *     happens when the input contains more than {@code maxOpLength}
     *     consecutive bytes that no match can cover
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit, int maxOpLength) {
        int maxOffset = offsetCeiling(input.length - 1, offsetLimit);
        @Nullable Block[] lastLiteral = new @Nullable Block[maxOffset + 1];
        var lastMatch = new @Nullable Block[maxOffset + 1];
        var optimal = new @Nullable Block[input.length];
        int[] matchLength = new int[maxOffset + 1];
        int[] bestLength = new int[Math.max(input.length, 3)];
        bestLength[2] = 2;

        // Start with a fake block for the first real block to chain from.
        lastMatch[INITIAL_OFFSET] = new Block(-1, skip - 1, INITIAL_OFFSET, null);

        System.out.print("[");
        int dots = 2;

        // Process remaining bytes.
        for (int index = skip; index < input.length; index++) {
            int bestLengthSize = 2;
            maxOffset = offsetCeiling(index, offsetLimit);
            for (int offset = 1; offset <= maxOffset; offset++) {
                if (index != skip && index >= offset && input[index] == input[index - offset]) {
                    // Copy from last offset.
                    Block literal = lastLiteral[offset];
                    if (literal != null && index - literal.index() <= maxOpLength) {
                        int length = index - literal.index();
                        int bits = literal.bits() + 1 + eliasGammaBits(length);
                        Block match = new Block(bits, index, offset, literal);
                        lastMatch[offset] = match;
                        optimal[index] = better(optimal[index], match);
                    }
                    // Copy from new offset.
                    int reach = Math.min(++matchLength[offset], maxOpLength);
                    if (reach > 1) {
                        if (bestLengthSize < reach) {
                            Block best = optimal[index - bestLength[bestLengthSize]];
                            // Unreachable positions exist only under a length
                            // limit; without one every predecessor is present,
                            // as the original asserts stated.
                            int bits = best == null ? Integer.MAX_VALUE
                                    : best.bits() + eliasGammaBits(bestLength[bestLengthSize] - 1);
                            do {
                                bestLengthSize++;
                                Block shorter = optimal[index - bestLengthSize];
                                int bits2 = shorter == null ? Integer.MAX_VALUE
                                        : shorter.bits() + eliasGammaBits(bestLengthSize - 1);
                                if (shorter != null && bits2 <= bits) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = bits2;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < reach);
                        }
                        int length = bestLength[reach];
                        Block previous = optimal[index - length];
                        if (previous != null) {
                            int bits = previous.bits() + 1 + (offset > 128 ? 16 : 8) + eliasGammaBits(length - 1);
                            Block match = lastMatch[offset];
                            if (match == null || match.index() != index || match.bits() > bits) {
                                match = new Block(bits, index, offset, previous);
                                lastMatch[offset] = match;
                                optimal[index] = better(optimal[index], match);
                            }
                        }
                    }
                } else {
                    // Copy literals.
                    matchLength[offset] = 0;
                    Block match = lastMatch[offset];
                    if (match != null && index - match.index() <= maxOpLength) {
                        int length = index - match.index();
                        int bits = match.bits() + 1 + eliasGammaBits(length) + length * 8;
                        Block literal = new Block(bits, index, 0, match);
                        lastLiteral[offset] = literal;
                        optimal[index] = better(optimal[index], literal);
                    } else {
                        // The "copy from last offset" branch above chains a match
                        // back to lastLiteral[offset] on the strength of this
                        // assignment: it marks the most recent mismatch, so every
                        // byte after it is known to match at this offset. Leaving
                        // a stale block here when the run is too long to encode
                        // would let a later match span bytes that do not match.
                        lastLiteral[offset] = null;
                    }
                }
            }

            // Indicate progress.
            if ((long) index * MAX_SCALE / input.length > dots) {
                System.out.print(".");
                System.out.flush();
                dots++;
            }
        }

        System.out.println("]");

        Block last = optimal[input.length - 1];
        if (last == null) {
            throw new IllegalArgumentException(
                    "No parse exists with operations limited to " + maxOpLength
                    + " bytes: the input contains a longer stretch that no match covers");
        }
        return last;
    }

    private static Block better(@Nullable Block current, Block candidate) {
        return current == null || current.bits() > candidate.bits() ? candidate : current;
    }
}
