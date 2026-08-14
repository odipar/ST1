package org.jx1;

import java.util.ArrayDeque;

/**
 * ZX1 bitstream writer. Java port of {@code compress.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Compressor {

    /** Compressed stream plus the delta needed for safe in-place decompression. */
    public record Result(byte[] output, int delta) {}

    private final byte[] input;
    private final byte[] output;
    private int inputIndex;
    private int outputIndex;
    private int bitIndex;
    private int bitMask;
    private int diff;
    private int delta;

    private Compressor(byte[] input, byte[] output, int skip) {
        this.input = input;
        this.output = output;
        this.inputIndex = skip;
        this.diff = output.length - input.length + skip;
    }

    public static Result compress(Block optimal, byte[] input, int skip, boolean backwardsMode) {
        byte[] output = new byte[(optimal.bits() + 24) / 8];
        return new Compressor(input, output, skip).run(optimal, backwardsMode);
    }

    private Result run(Block optimal, boolean backwardsMode) {
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
            } else if (block.offset() == lastOffset && afterLiterals) {
                // Copy from last offset indicator and length.
                writeBit(false);
                writeInterlacedEliasGamma(length);
                readBytes(length);
                afterLiterals = false;
            } else {
                // Copy from new offset indicator.
                writeBit(true);

                // Copy from new offset.
                int offset = block.offset();
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
                writeInterlacedEliasGamma(length - 1);
                readBytes(length);

                lastOffset = offset;
                afterLiterals = false;
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

        return new Result(output, delta);
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
