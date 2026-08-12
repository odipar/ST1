package org.jx1;

import java.util.Arrays;

/**
 * ZX1 decompressor. Java port of {@code dzx1.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 *
 * <p>The C original streams through a 64K ring buffer and uses {@code goto}; here the output
 * simply grows in memory and the control flow is restructured into loops.
 */
public final class Decompressor {

    private final byte[] input;
    private int inputIndex;
    private int bitMask;
    private int bitValue;

    /** Largest array the JVM can reliably allocate; caps output at ~2 GiB (the C original streams unbounded). */
    private static final int MAX_OUTPUT_SIZE = Integer.MAX_VALUE - 8;

    private byte[] output = new byte[65536];
    private int outputIndex;

    private Decompressor(byte[] input) {
        this.input = input;
    }

    /** Decompresses a complete ZX1 stream; throws {@link IllegalArgumentException} on bad data. */
    public static byte[] decompress(byte[] input) {
        return new Decompressor(input).run();
    }

    private byte[] run() {
        int lastOffset = Optimizer.INITIAL_OFFSET;
        while (true) {
            // Copy literals.
            int length = readInterlacedEliasGamma();
            for (int i = 0; i < length; i++) {
                writeByte(readByte());
            }
            if (!readBit()) {
                // Copy from last offset.
                copyBytes(lastOffset, readInterlacedEliasGamma());
                if (!readBit()) {
                    continue;
                }
            }
            do {
                // Copy from new offset; an offset <= 0 is the end marker.
                lastOffset = readOffset();
                if (lastOffset <= 0) {
                    if (inputIndex != input.length) {
                        throw new IllegalArgumentException("Input file too long");
                    }
                    return Arrays.copyOf(output, outputIndex);
                }
                copyBytes(lastOffset, readInterlacedEliasGamma() + 1);
            } while (readBit());
        }
    }

    private int readOffset() {
        int offset = readByte();
        if ((offset & 1) != 0) {
            int high = readByte();
            return 32512 - (high & 254) * 128 - (offset & 254) - (high & 1);
        }
        return 128 - offset / 2;
    }

    private int readByte() {
        if (inputIndex == input.length) {
            throw new IllegalArgumentException(
                    input.length == 0 ? "Empty input file" : "Truncated input file");
        }
        return input[inputIndex++] & 255;
    }

    private boolean readBit() {
        bitMask >>= 1;
        if (bitMask == 0) {
            bitMask = 128;
            bitValue = readByte();
        }
        return (bitValue & bitMask) != 0;
    }

    private int readInterlacedEliasGamma() {
        int value = 1;
        while (readBit()) {
            value = value << 1 | (readBit() ? 1 : 0);
        }
        return value;
    }

    private void writeByte(int value) {
        if (outputIndex == output.length) {
            if (output.length == MAX_OUTPUT_SIZE) {
                throw new IllegalArgumentException("Output too large from input file");
            }
            output = Arrays.copyOf(output, (int) Math.min(2L * output.length, MAX_OUTPUT_SIZE));
        }
        output[outputIndex++] = (byte) value;
    }

    private void copyBytes(int offset, int length) {
        if (offset > outputIndex) {
            throw new IllegalArgumentException("Invalid data in input file");
        }
        for (int i = 0; i < length; i++) {
            writeByte(output[outputIndex - offset]);
        }
    }
}
