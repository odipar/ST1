package org.jx1;

import java.util.ArrayDeque;
import java.util.Arrays;

/**
 * ZX1 bitstream writer. Java port of {@code compress.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Compressor {

    /**
     * Compressed stream, the delta needed for safe in-place decompression, and
     * the longest single operation it contains - which a caller targeting the
     * 68000 decoders wants to be at most 65535.
     */
    public record Result(byte[] output, int delta, int longestOp) {}

    private final byte[] input;
    private final byte[] output;
    private int inputIndex;
    private int outputIndex;
    private int bitIndex;
    private int bitMask;
    private int diff;
    private int delta;
    private int longestOp;

    private Compressor(byte[] input, byte[] output, int skip) {
        this.input = input;
        this.output = output;
        this.inputIndex = skip;
        this.diff = output.length - input.length + skip;
    }

    public static Result compress(Block optimal, byte[] input, int skip, boolean backwardsMode) {
        return compress(optimal, input, skip, backwardsMode, Integer.MAX_VALUE);
    }

    /**
     * As above, but no emitted operation exceeds {@code maxOpLength} bytes where
     * the format allows it to be avoided: an over-long match is written as
     * several matches at the same offset. A literal run cannot be split - after
     * a literal run a 0 bit means a match, so the format has no way to say "more
     * literals" - which is why {@link Optimizer} steers the parse away from long
     * ones instead. {@link Result#longestOp()} reports what actually came out.
     */
    public static Result compress(Block optimal, byte[] input, int skip, boolean backwardsMode,
                                  int maxOpLength) {
        byte[] output = new byte[(optimal.bits() + 24) / 8 + splitHeadroom(optimal, maxOpLength)];
        return new Compressor(input, output, skip).run(optimal, backwardsMode, maxOpLength);
    }

    /** Bytes for the extra operations splitting introduces: at most 50 bits each. */
    private static int splitHeadroom(Block optimal, int maxOpLength) {
        int extra = 0;
        for (Block block = optimal; block != null && block.chain() != null; block = block.chain()) {
            if (block.offset() != 0) {
                extra += (block.index() - block.chain().index() - 1) / maxOpLength;
            }
        }
        return extra * 8;
    }

    private Result run(Block optimal, boolean backwardsMode, int maxOpLength) {
        // Un-reverse the optimal sequence; its head is the parser's fake block.
        var blocks = new ArrayDeque<Block>();
        for (Block block = optimal; block != null; block = block.chain()) {
            blocks.push(block);
        }
        Block prev = blocks.pop();

        int lastOffset = Optimizer.INITIAL_OFFSET;
        boolean first = true;
        // The format alternates: a 0 bit means "match at the last offset" only
        // after a literal run - after a match it means literals. An
        // unconstrained parse never places two matches back to back at one
        // offset (it would merge them into a longer, cheaper one), but a parse
        // constrained by a maximum operation length does exactly that, so the
        // short encoding has to be earned rather than assumed.
        boolean afterLiterals = false;

        // Generate output.
        for (Block block : blocks) {
            int length = block.index() - prev.index();
            prev = block;

            if (block.offset() == 0) {
                // Copy literals indicator, except before the very first block.
                if (first) {
                    first = false;
                } else {
                    writeBit(false);
                }

                // Copy literals length and values.
                writeInterlacedEliasGamma(length);
                for (int i = 0; i < length; i++) {
                    writeByte(input[inputIndex]);
                    readBytes(1);
                }
                afterLiterals = true;
                longestOp = Math.max(longestOp, length);
            } else {
                // A match, in as many operations as the length limit needs. Each
                // one after the first has to name the offset again: it follows a
                // match, where a 0 bit would mean literals rather than "same
                // offset". Costing two or three bytes once per 65535 is why this
                // is a split rather than a parse constraint.
                int offset = block.offset();
                // Split evenly rather than greedily. Greedy leaves a remainder,
                // and a remainder of one byte cannot be written at all: every
                // piece after the first has to be a new-offset match, whose
                // minimum length is two. An even split of a length of two or
                // more into pieces of at most maxOpLength gives every piece at
                // least two, provided maxOpLength is at least three - below
                // that the match goes out whole and longestOp reports it.
                int pieces = maxOpLength < 3 ? 1 : (length - 1) / maxOpLength + 1;
                int base = length / pieces;
                int wider = length % pieces;
                for (int i = 0; i < pieces; i++) {
                    int piece = base + (i < wider ? 1 : 0);
                    if (afterLiterals && offset == lastOffset) {
                        // Copy from last offset indicator and length.
                        writeBit(false);
                        writeInterlacedEliasGamma(piece);
                        readBytes(piece);
                        afterLiterals = false;
                    } else {
                        // Copy from new offset indicator.
                        writeBit(true);
                        if (backwardsMode) {
                            if (offset > 128) {
                                writeByte(((offset - 1) & 254) + 1);
                                writeByte(offset / 256 * 2 + (offset - 1) % 2 + 2);
                            } else {
                                writeByte((offset - 1) * 2);
                            }
                        } else {
                            if (offset > 128) {
                                writeByte(255 - ((offset - 1) & 254));
                                writeByte(252 - (offset - 1) / 256 * 2 + offset % 2);
                            } else {
                                writeByte(256 - offset * 2);
                            }
                        }

                        // Copy from new offset length.
                        writeInterlacedEliasGamma(piece - 1);
                        readBytes(piece);
                        lastOffset = offset;
                        afterLiterals = false;
                    }
                    longestOp = Math.max(longestOp, piece);
                }
            }
        }

        // End marker.
        writeBit(true);
        if (backwardsMode) {
            writeByte(1);
            writeByte(0);
        } else {
            writeByte(255);
            writeByte(255);
        }

        // The buffer is sized generously - penalties inflate the parse's bit
        // count, and splitting adds operations - so trim it, and shift the delta
        // by the same amount: every diff was computed against the larger size.
        int over = output.length - outputIndex;
        return new Result(Arrays.copyOf(output, outputIndex), Math.max(0, delta - over), longestOp);
    }

    private void readBytes(int n) {
        inputIndex += n;
        diff += n;
        if (delta < diff) {
            delta = diff;
        }
    }

    private void writeByte(int value) {
        output[outputIndex++] = (byte) value;
        diff--;
    }

    private void writeBit(boolean value) {
        if (bitMask == 0) {
            bitMask = 128;
            bitIndex = outputIndex;
            writeByte(0);
        }
        if (value) {
            output[bitIndex] |= bitMask;
        }
        bitMask >>= 1;
    }

    private void writeInterlacedEliasGamma(int value) {
        for (int i = Integer.highestOneBit(value) >> 1; i != 0; i >>= 1) {
            writeBit(true);
            writeBit((value & i) != 0);
        }
        writeBit(false);
    }
}
