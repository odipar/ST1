package org.jx1;

import static java.util.Objects.requireNonNull;

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
        int maxOffset = offsetCeiling(input.length - 1, offsetLimit);
        var lastLiteral = new @Nullable Block[maxOffset + 1];
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
                            int bits = requireNonNull(optimal[index - bestLength[bestLengthSize]]).bits()
                                    + eliasGammaBits(bestLength[bestLengthSize] - 1);
                            do {
                                bestLengthSize++;
                                int bits2 = requireNonNull(optimal[index - bestLengthSize]).bits()
                                        + eliasGammaBits(bestLengthSize - 1);
                                if (bits2 <= bits) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = bits2;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < matchLength[offset]);
                        }
                        int length = bestLength[matchLength[offset]];
                        Block previous = requireNonNull(optimal[index - length]);
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

            // Indicate progress.
            if ((long) index * MAX_SCALE / input.length > dots) {
                System.out.print(".");
                System.out.flush();
                dots++;
            }
        }

        System.out.println("]");

        return requireNonNull(optimal[input.length - 1]);
    }

    private static Block better(@Nullable Block current, Block candidate) {
        return current == null || current.bits() > candidate.bits() ? candidate : current;
    }
}
