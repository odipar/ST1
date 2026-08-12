package org.jx1;

import java.io.ByteArrayOutputStream;

/**
 * ZX1 decompressor. Java port of {@code dzx1.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 *
 * <p>Output streams through an externally supplied ring buffer, so memory use is bounded by the
 * buffer, not the output: a buffer of size N supports back-references up to N bytes, and each time
 * the buffer fills {@link #flip} decides where its bytes go. Subclass to stream output anywhere;
 * the static {@link #decompress(byte[], byte[])} methods collect it in memory.
 */
public abstract class Decompressor {

    /** Ring buffer size of the C reference implementation; covers the full ZX1 offset range. */
    public static final int DEFAULT_BUFFER_SIZE = 65536;

    private final byte[] input;
    private final byte[] buffer;
    private int inputIndex;
    private int bitMask;
    private int bitValue;
    private int bufferIndex;
    private long flushedSize;

    protected Decompressor(byte[] input, byte[] buffer) {
        if (buffer.length == 0) {
            throw new IllegalArgumentException("Empty ring buffer");
        }
        this.input = input;
        this.buffer = buffer;
    }

    /**
     * Consumes the first {@code length} bytes of the ring buffer: called with a full buffer each
     * time it flips, and once more at the end of the stream for the remaining bytes, if any.
     */
    protected abstract void flip(byte[] buffer, int length);

    /** Decompresses a complete ZX1 stream in memory, using the default buffer size. */
    public static byte[] decompress(byte[] input) {
        return decompress(input, new byte[DEFAULT_BUFFER_SIZE]);
    }

    /** Decompresses a complete ZX1 stream in memory, through the given ring buffer. */
    public static byte[] decompress(byte[] input, byte[] buffer) {
        var output = new ByteArrayOutputStream();
        new Decompressor(input, buffer) {
            @Override
            protected void flip(byte[] flipped, int length) {
                output.write(flipped, 0, length);
            }
        }.decompress();
        return output.toByteArray();
    }

    /**
     * Decompresses the whole input stream; throws {@link IllegalArgumentException} on bad data.
     * Resets all stream state on entry, so an instance may be reused.
     */
    public final void decompress() {
        inputIndex = 0;
        bitMask = 0;
        bitValue = 0;
        bufferIndex = 0;
        flushedSize = 0;

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
                    if (bufferIndex != 0) {
                        flip(buffer, bufferIndex);
                    }
                    if (inputIndex != input.length) {
                        throw new IllegalArgumentException("Input file too long");
                    }
                    return;
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
        buffer[bufferIndex++] = (byte) value;
        if (bufferIndex == buffer.length) {
            flip(buffer, bufferIndex);
            flushedSize += bufferIndex;
            bufferIndex = 0;
        }
    }

    private void copyBytes(int offset, int length) {
        if (offset > flushedSize + bufferIndex) {
            throw new IllegalArgumentException("Invalid data in input file");
        }
        if (offset > buffer.length) {
            throw new IllegalArgumentException("Backreference beyond ring buffer in input file");
        }
        for (int i = 0; i < length; i++) {
            int index = bufferIndex - offset;
            writeByte(buffer[index >= 0 ? index : buffer.length + index]);
        }
    }
}
