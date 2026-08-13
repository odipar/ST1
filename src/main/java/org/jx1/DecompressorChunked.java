package org.jx1;

import java.io.ByteArrayOutputStream;

/**
 * Decompressor for the chunk-aligned ZX1 variant of {@link CompressorChunked}.
 * The format guarantees that no op crosses a multiple-of-{@code chunkSize}
 * output boundary, so {@link #resume()} needs no mid-op state and no per-byte
 * budget accounting: it decodes whole ops until exactly one chunk is emitted
 * (the final chunk may be short), and between calls the only state is the bit
 * reader, the last offset, and which grammar phase the next chunk starts in.
 *
 * <p>Output streams through the same ring-buffer {@link #flip} contract as
 * {@link Decompressor}.
 *
 * <p>Malformed data trips Java assertions (enable with {@code -ea}); with
 * assertions disabled, behavior on malformed data is undefined.
 */
public abstract class DecompressorChunked {

    private enum State { FIRST, BOUNDARY, DONE }

    private final byte[] input;
    private final byte[] buffer;
    private final int chunkSize;
    private int inputIndex;
    private int bitMask;
    private int bitValue;
    private int bufferIndex;
    private long flushedSize;
    private int lastOffset;
    private State state;

    protected DecompressorChunked(byte[] input, byte[] buffer, int chunkSize) {
        assert buffer.length > 0 : "Empty ring buffer";
        assert chunkSize > 0 : "Chunk size must be positive";
        this.input = input;
        this.buffer = buffer;
        this.chunkSize = chunkSize;
        this.state = State.FIRST;
        this.lastOffset = Optimizer.INITIAL_OFFSET;
    }

    /** Same contract as {@link Decompressor#flip}. */
    protected abstract void flip(byte[] buffer, int length);

    /** Decompresses a complete chunked stream in memory. */
    public static byte[] decompress(byte[] input, int chunkSize) {
        var output = new ByteArrayOutputStream();
        var decompressor = new DecompressorChunked(input, new byte[65536], chunkSize) {
            @Override
            protected void flip(byte[] flipped, int length) {
                output.write(flipped, 0, length);
            }
        };
        while (decompressor.resume()) {}
        return output.toByteArray();
    }

    /**
     * Emits exactly one chunk, returning {@code true} after each full chunk.
     * The closing call emits the final short chunk (if any) and returns
     * {@code false}; when the output is an exact multiple of the chunk size,
     * the closing call emits nothing.
     */
    public final boolean resume() {
        if (state == State.DONE) {
            return false;
        }
        int budget = chunkSize;
        boolean literalsNext = true;
        if (state == State.FIRST) {
            state = State.BOUNDARY;                   // streams open with literals
        } else if (readBit()) {                       // boundary code: 0 = literals, 11 =
            if (readBit()) {                          // full-chunk from-last (implied
                copyMatch(budget, budget);            // length, no gamma), 100 =
                return true;                          // from-last, 101 = new-offset
            }
            if (readBit()) {
                literalsNext = false;                 // 101: new-offset opens the chunk
            } else {                                  // 100: from-last opens the chunk
                budget -= copyMatch(readInterlacedEliasGamma(), budget);
                if (budget == 0) {
                    return true;
                }
                literalsNext = !readBit();            // then the normal after-match bit
            }
        }
        while (true) {
            assert budget > 0 : "Invalid data: op past chunk boundary";
            if (literalsNext) {
                int length = readInterlacedEliasGamma();
                assert length <= budget : "Invalid data: literals cross a chunk boundary";
                for (int i = 0; i < length; i++) {
                    writeByte(readByte());
                }
                budget -= length;
                if (budget == 0) {
                    return true;
                }
                if (readBit()) {                      // after-literals: 1 = new offset
                    if (!beginNewOffset()) {
                        return false;                 // end marker
                    }
                    budget -= copyMatch(readInterlacedEliasGamma() + 1, budget);
                } else {                              // 0 = from last offset
                    budget -= copyMatch(readInterlacedEliasGamma(), budget);
                }
            } else {                                  // chunk opens with a match
                if (!beginNewOffset()) {
                    return false;                     // end marker
                }
                budget -= copyMatch(readInterlacedEliasGamma() + 1, budget);
            }
            if (budget == 0) {
                return true;
            }
            literalsNext = !readBit();                // after-match transition
        }
    }

    /** Reads a new offset; false means the end marker was found (state = DONE). */
    private boolean beginNewOffset() {
        int offset = readByte();
        if ((offset & 1) != 0) {
            int high = readByte();
            offset = 32512 - (high & 254) * 128 - (offset & 254) - (high & 1);
        } else {
            offset = 128 - offset / 2;
        }
        if (offset <= 0) {
            if (bufferIndex != 0) {
                flip(buffer, bufferIndex);
            }
            assert inputIndex == input.length : "Input file too long";
            state = State.DONE;
            return false;
        }
        lastOffset = offset;
        return true;
    }

    private int copyMatch(int length, int budget) {
        assert length <= budget : "Invalid data: match crosses a chunk boundary";
        assert lastOffset <= flushedSize + bufferIndex : "Invalid data in input file";
        assert lastOffset <= buffer.length : "Backreference beyond ring buffer";
        for (int i = 0; i < length; i++) {
            int index = bufferIndex - lastOffset;
            writeByte(buffer[index >= 0 ? index : buffer.length + index]);
        }
        return length;
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

    private void writeByte(int value) {
        buffer[bufferIndex++] = (byte) value;
        if (bufferIndex == buffer.length) {
            flip(buffer, bufferIndex);
            flushedSize += bufferIndex;
            bufferIndex = 0;
        }
    }

    /** Minimal CLI for the emulation harness: input output chunkSize. */
    public static void main(String[] args) throws java.io.IOException {
        byte[] input = java.nio.file.Files.readAllBytes(java.nio.file.Path.of(args[0]));
        byte[] output = decompress(input, Integer.parseInt(args[2]));
        java.nio.file.Files.write(java.nio.file.Path.of(args[1]), output);
        System.out.printf("File chunk-decompressed from %d to %d bytes!%n", input.length, output.length);
    }
}
