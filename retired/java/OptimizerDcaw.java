package org.jx1;

import org.jspecify.annotations.Nullable;

/**
 * Decode-cost-aware optimal LZ parser for the ZX1 format: the same dynamic
 * program as {@link Optimizer}, but each op is scored as
 * {@code (bits << 8) + lambda * decodeCycles(op)}, so the parse can trade a
 * little compression ratio for measurably faster decompression. The cycle
 * constants are the parse-variant costs of the 68000 decoders (per-op
 * dispatch, gamma parsing, offset decoding; per-byte copy cycles are the same
 * for every parse and drop out of the comparison).
 *
 * <p>{@code lambda = 0} reproduces the bit-optimal parse. The returned chain
 * carries TRUE bit counts (a corrector pass rewrites the scores), so it feeds
 * straight into {@link Compressor#compress} and produces streams that every
 * existing decompressor reads unchanged.
 */
public final class OptimizerDcaw {

    private OptimizerDcaw() {}

    private static int offsetCeiling(int index, int offsetLimit) {
        return Math.clamp(index, Optimizer.INITIAL_OFFSET, offsetLimit);
    }

    private static int eliasGammaBits(int value) {
        int bits = 1;
        while ((value >>= 1) != 0) {
            bits += 2;
        }
        return bits;
    }

    /** Cycles the 68k decoders spend parsing a gamma of this value. */
    private static int gammaCycles(int value) {
        return 26 + 32 * (31 - Integer.numberOfLeadingZeros(value));
    }

    /** Score of a literals op of this length (excluding parse-invariant copy cycles). */
    private static int literalsScore(int length, int lambda) {
        int bits = 1 + eliasGammaBits(length) + 8 * length;
        return (bits << 8) + lambda * (74 + gammaCycles(length));
    }

    /** Score of a from-last-offset match of this length. */
    private static int lastOffsetScore(int length, int lambda) {
        int bits = 1 + eliasGammaBits(length);
        return (bits << 8) + lambda * (82 + gammaCycles(length));
    }

    /** Score of a new-offset match of this length at this offset. */
    private static int newOffsetScore(int offset, int length, int lambda) {
        int bits = 1 + (offset > 128 ? 16 : 8) + eliasGammaBits(length - 1);
        return (bits << 8)
                + lambda * (130 + gammaCycles(length - 1) + (offset > 128 ? 20 : 0));
    }

    /**
     * Returns the last block of the score-optimal parse chain, with the chain's
     * {@code bits} fields corrected to true bit counts.
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit, int lambda) {
        int maxOffset = offsetCeiling(input.length - 1, offsetLimit);
        var lastLiteral = new @Nullable Block[maxOffset + 1];
        var lastMatch = new @Nullable Block[maxOffset + 1];
        var optimal = new @Nullable Block[input.length];
        int[] matchLength = new int[maxOffset + 1];
        int[] bestLength = new int[Math.max(input.length, 3)];
        bestLength[2] = 2;

        // The fake block: -1 bit in score units, so the skipped first literals
        // indicator cancels exactly as in Optimizer.
        lastMatch[Optimizer.INITIAL_OFFSET] =
                new Block(-(1 << 8), skip - 1, Optimizer.INITIAL_OFFSET, null);

        for (int index = skip; index < input.length; index++) {
            int bestLengthSize = 2;
            maxOffset = offsetCeiling(index, offsetLimit);
            for (int offset = 1; offset <= maxOffset; offset++) {
                if (index != skip && index >= offset && input[index] == input[index - offset]) {
                    Block literal = lastLiteral[offset];
                    if (literal != null) {
                        int length = index - literal.index();
                        int score = literal.bits() + lastOffsetScore(length, lambda);
                        Block match = new Block(score, index, offset, literal);
                        lastMatch[offset] = match;
                        optimal[index] = better(optimal[index], match);
                    }
                    if (++matchLength[offset] > 1) {
                        if (bestLengthSize < matchLength[offset]) {
                            Block best = optimal[index - bestLength[bestLengthSize]];
                            assert best != null;
                            int score = best.bits()
                                    + newOffsetScore(129, bestLength[bestLengthSize], lambda);
                            do {
                                bestLengthSize++;
                                Block shorter = optimal[index - bestLengthSize];
                                assert shorter != null;
                                int score2 = shorter.bits()
                                        + newOffsetScore(129, bestLengthSize, lambda);
                                if (score2 <= score) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    score = score2;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < matchLength[offset]);
                        }
                        int length = bestLength[matchLength[offset]];
                        Block previous = optimal[index - length];
                        assert previous != null;
                        int score = previous.bits() + newOffsetScore(offset, length, lambda);
                        Block match = lastMatch[offset];
                        if (match == null || match.index() != index || match.bits() > score) {
                            match = new Block(score, index, offset, previous);
                            lastMatch[offset] = match;
                            optimal[index] = better(optimal[index], match);
                        }
                    }
                } else {
                    matchLength[offset] = 0;
                    Block match = lastMatch[offset];
                    if (match != null) {
                        int length = index - match.index();
                        int score = match.bits() + literalsScore(length, lambda);
                        Block literal = new Block(score, index, 0, match);
                        lastLiteral[offset] = literal;
                        optimal[index] = better(optimal[index], literal);
                    }
                }
            }
        }

        Block last = optimal[input.length - 1];
        assert last != null;
        return correctBits(last, skip);
    }

    /** Rebuilds the chain with true bit counts so Compressor sizes its buffer right. */
    private static Block correctBits(Block tail, int skip) {
        var blocks = new java.util.ArrayDeque<Block>();
        for (Block b = tail; b != null; b = b.chain()) {
            blocks.push(b);
        }
        Block head = blocks.pop();                    // the fake block
        Block corrected = new Block(-1, head.index(), head.offset(), null);
        int lastOffset = Optimizer.INITIAL_OFFSET;
        Block prev = head;
        for (Block b : blocks) {
            int length = b.index() - prev.index();
            int bits;
            if (b.offset() == 0) {
                bits = 1 + eliasGammaBits(length) + 8 * length;
            } else if (b.offset() == lastOffset) {
                bits = 1 + eliasGammaBits(length);
            } else {
                bits = 1 + (b.offset() > 128 ? 16 : 8) + eliasGammaBits(length - 1);
            }
            if (b.offset() != 0) {
                lastOffset = b.offset();
            }
            corrected = new Block(corrected.bits() + bits, b.index(), b.offset(), corrected);
            prev = b;
        }
        return corrected;
    }

    private static Block better(@Nullable Block current, Block candidate) {
        return current == null || current.bits() > candidate.bits() ? candidate : current;
    }

    /** Minimal CLI for the harness: input output lambda [offsetLimit]. */
    public static void main(String[] args) throws java.io.IOException {
        byte[] input = java.nio.file.Files.readAllBytes(java.nio.file.Path.of(args[0]));
        int lambda = Integer.parseInt(args[2]);
        int offsetLimit = args.length > 3 ? Integer.parseInt(args[3]) : Zx1.MAX_OFFSET_ZX1;
        Compressor.Result result = Compressor.compress(
                optimize(input, 0, offsetLimit, lambda), input, 0, false);
        java.nio.file.Files.write(java.nio.file.Path.of(args[1]), result.output());
        System.out.printf("File dcaw-compressed from %d to %d bytes! (lambda %d, delta %d)%n",
                input.length, result.output().length, lambda, result.delta());
    }
}
