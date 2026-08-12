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
 *
 * <p>Decompression is also resumable: {@link #resume()} produces at most {@code chunkSize} output
 * bytes (set at construction) before returning control to the caller, and returns {@code false}
 * once the stream is fully processed. {@link #decompress()} drains the whole stream in one call.
 *
 * <p>Malformed data trips Java assertions (enable with {@code -ea}); with assertions disabled,
 * behavior on malformed data is undefined, like the z80/68k decompressors.
 */
public abstract class Decompressor {

    /** Ring buffer size of the C reference implementation; covers the full ZX1 offset range. */
    public static final int DEFAULT_BUFFER_SIZE = 65536;

    /** The operation currently emitting bytes; parsing happens on the transitions between them. */
    private enum State { START, LITERALS, MATCH, DONE }

    private final byte[] input;
    private final byte[] buffer;
    private final int chunkSize;
    private int inputIndex;
    private int bitMask;
    private int bitValue;
    private int bufferIndex;
    private long flushedSize;
    private int lastOffset;
    private int remaining;
    private State state = State.START;

    /** Uses the ring buffer's size as the {@code resume()} chunk size. */
    protected Decompressor(byte[] input, byte[] buffer) {
        this(input, buffer, buffer.length);
    }

    protected Decompressor(byte[] input, byte[] buffer, int chunkSize) {
        assert buffer.length > 0 : "Empty ring buffer";
        assert chunkSize > 0 : "Chunk size must be positive";
        this.input = input;
        this.buffer = buffer;
        this.chunkSize = chunkSize;
        reset();
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

    /** Decompresses the whole input stream. Resets all stream state on entry, so an instance may be reused. */
    public final void decompress() {
        reset();
        while (resume()) {}
    }

    /**
     * Produces at most one chunk of output bytes, then returns control to the caller; call again
     * to continue. Returns {@code false} once the stream is fully processed. ({@code continue}
     * is a reserved word in Java, hence {@code resume}.)
     */
    public final boolean resume() {
        int budget = chunkSize;
        while (state != State.DONE) {
            if (remaining == 0) {
                next();
            } else if (budget == 0) {
                return true;
            } else {
                writeByte(state == State.LITERALS ? readByte() : readBufferByte());
                remaining--;
                budget--;
            }
        }
        return false;
    }

    private void reset() {
        inputIndex = 0;
        bitMask = 0;
        bitValue = 0;
        bufferIndex = 0;
        flushedSize = 0;
        lastOffset = Optimizer.INITIAL_OFFSET;
        remaining = 0;
        state = State.START;
    }

    /** Parses the next block header and transitions the state machine; {@code dzx1.c}'s goto graph. */
    private void next() {
        switch (state) {
            case START -> beginLiterals();
            case LITERALS -> {
                if (readBit()) {
                    beginMatchFromNewOffset();
                } else {
                    beginMatchFromLastOffset();
                }
            }
            case MATCH -> {
                if (readBit()) {
                    beginMatchFromNewOffset();
                } else {
                    beginLiterals();
                }
            }
            case DONE -> throw new AssertionError("unreachable");
        }
    }

    private void beginLiterals() {
        remaining = readInterlacedEliasGamma();
        assert remaining > 0 : "Invalid data in input file";
        state = State.LITERALS;
    }

    private void beginMatchFromLastOffset() {
        remaining = readInterlacedEliasGamma();
        assert remaining > 0 : "Invalid data in input file";
        checkOffset();
        state = State.MATCH;
    }

    private void beginMatchFromNewOffset() {
        int offset = readOffset();
        if (offset <= 0) {
            // End marker: flush the remainder, like the C original writes before its checks.
            if (bufferIndex != 0) {
                flip(buffer, bufferIndex);
            }
            assert inputIndex == input.length : "Input file too long";
            state = State.DONE;
            return;
        }
        lastOffset = offset;
        remaining = readInterlacedEliasGamma() + 1;
        assert remaining > 0 : "Invalid data in input file";
        checkOffset();
        state = State.MATCH;
    }

    private void checkOffset() {
        assert lastOffset <= flushedSize + bufferIndex : "Invalid data in input file";
        assert lastOffset <= buffer.length : "Backreference beyond ring buffer in input file";
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
        assert inputIndex < input.length
                : input.length == 0 ? "Empty input file" : "Truncated input file";
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

    private int readBufferByte() {
        int index = bufferIndex - lastOffset;
        return buffer[index >= 0 ? index : buffer.length + index];
    }

    private void writeByte(int value) {
        buffer[bufferIndex++] = (byte) value;
        if (bufferIndex == buffer.length) {
            flip(buffer, bufferIndex);
            flushedSize += bufferIndex;
            bufferIndex = 0;
        }
    }
}
