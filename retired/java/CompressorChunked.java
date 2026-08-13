package org.jx1;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Chunk-aligned ZX1 variant compressor: no literal run or match ever crosses a
 * multiple-of-{@code chunkSize} boundary in the output, so a decompressor that
 * resumes every {@code chunkSize} bytes never needs mid-op state or per-byte
 * budget accounting.
 *
 * <p>The op encodings are ZX1's. The grammar differs in one place: at every
 * chunk boundary the stream carries a <em>boundary code</em> telling how the
 * chunk opens - {@code 0} literals, {@code 11} a from-last match spanning the
 * WHOLE chunk with its length implied (no gamma - the dominant case when a
 * long match is split at boundaries, and the reason boundary-split matches
 * cost only two bits per chunk), {@code 100} a partial from-last match,
 * {@code 101} a new-offset match. The first chunk opens with literals like a
 * normal ZX1 stream. The code lengths keep every chunk's bit count even, so
 * gammas stay even-bit-aligned and the bit-queue refill invariant of the 68k
 * decompressors is preserved - with one addition: the second boundary bit
 * sits on a refill-exposed even index, so the 68k reads it with a refill
 * check.
 *
 * <p>The parse is greedy (hash-chain match finder, cost-based choice), not
 * optimal like {@link Optimizer}; the ratio cost is the price of the format.
 * No skip/backwards modes.
 */
public final class CompressorChunked {

    /** Compressed stream plus the delta needed for safe in-place decompression. */
    public record Result(byte[] output, int delta) {}

    private static final int MAX_CHAIN = 128;

    private record Op(int length, int offset) {}   // offset 0 = literals, -1 = from-last,
                                                    // -2 = full-chunk from-last (code 11)

    private final byte[] input;
    private final int chunkSize;
    private final int offsetLimit;
    private final int[] head = new int[65536];
    private final int[] prev;

    private CompressorChunked(byte[] input, int chunkSize, int offsetLimit) {
        this.input = input;
        this.chunkSize = chunkSize;
        this.offsetLimit = offsetLimit;
        this.prev = new int[input.length];
        java.util.Arrays.fill(head, -1);
    }

    public static Result compress(byte[] input, int chunkSize, int offsetLimit) {
        assert input.length > 0 : "Empty input";
        assert chunkSize > 0 : "Chunk size must be positive";
        return new CompressorChunked(input, chunkSize, offsetLimit).run();
    }

    private static int gammaBits(int value) {
        int bits = 1;
        while ((value >>= 1) != 0) {
            bits += 2;
        }
        return bits;
    }

    private int matchLength(int pos, int offset, int cap) {
        int n = 0;
        while (n < cap && input[pos + n] == input[pos + n - offset]) {
            n++;
        }
        return n;
    }

    private void insertHash(int pos) {
        if (pos + 1 < input.length) {
            int key = ((input[pos] & 255) << 8) | (input[pos + 1] & 255);
            prev[pos] = head[key];
            head[key] = pos;
        }
    }

    /** Longest match with the smallest offset on ties; returns {length, offset}. */
    private int[] bestMatch(int pos, int cap) {
        int bestLen = 0;
        int bestOff = 0;
        if (pos + 1 >= input.length || cap < 2) {
            return new int[] {0, 0};
        }
        int key = ((input[pos] & 255) << 8) | (input[pos + 1] & 255);
        int candidate = head[key];
        int chain = MAX_CHAIN;
        while (candidate >= 0 && chain-- > 0) {
            int offset = pos - candidate;
            if (offset > offsetLimit) {
                break;
            }
            int len = matchLength(pos, offset, cap);
            if (len > bestLen) {
                bestLen = len;
                bestOff = offset;
                if (len == cap) {
                    break;
                }
            }
            candidate = prev[candidate];
        }
        return new int[] {bestLen, bestOff};
    }

    private Result run() {
        // Pass 1: choose ops, chunk by chunk, respecting the grammar.
        List<Op> ops = new ArrayList<>();
        int lastOffset = Optimizer.INITIAL_OFFSET;
        int pos = 0;
        boolean firstBlock = true;
        while (pos < input.length) {
            int chunkEnd = Math.min(pos - pos % chunkSize + chunkSize, input.length);
            int literalRun = 0;
            while (pos < chunkEnd) {
                int room = chunkEnd - pos;
                // From-last candidate: directly after pending literals, or as the
                // opening op of a chunk (the 3-bit boundary code allows it there,
                // which is what keeps boundary-split long matches cheap).
                boolean atChunkStart = pos % chunkSize == 0 && pos > 0 && literalRun == 0;
                int lenA = (literalRun > 0 || atChunkStart) && pos >= lastOffset
                        ? matchLength(pos, lastOffset, room) : 0;
                int[] b = bestMatch(pos, room);
                int lenB = b[0];
                int offB = b[1];
                double bpbA = lenA > 0 ? (1.0 + gammaBits(lenA)) / lenA : 99;
                double bpbB = lenB >= 2
                        ? (1.0 + (offB <= 128 ? 8 : 16) + gammaBits(lenB - 1)) / lenB : 99;
                if (atChunkStart && lenA == room && room == chunkSize) {
                    bpbA = 2.0 / lenA;              // boundary code 11: two bits total
                }                                   // (only full-size chunks: the
                                                    // decoder implies length = chunk)
                boolean pickA = bpbA <= bpbB && bpbA < 8 && !firstBlock;
                boolean pickB = !pickA && bpbB < 8 && !firstBlock;
                if (pickA || pickB) {
                    if (literalRun > 0) {
                        ops.add(new Op(literalRun, 0));
                        literalRun = 0;
                    }
                    int len = pickA ? lenA : lenB;
                    if (pickB) {
                        lastOffset = offB;
                    }
                    ops.add(new Op(len, pickA
                            ? (atChunkStart && len == room && room == chunkSize ? -2 : -1)
                            : lastOffset));
                    for (int i = 0; i < len; i++) {
                        insertHash(pos + i);
                    }
                    pos += len;
                } else {
                    insertHash(pos);
                    pos++;
                    literalRun++;
                    firstBlock = false;
                }
            }
            if (literalRun > 0) {
                ops.add(new Op(literalRun, 0));
            }
        }

        // Pass 2: size the stream, then write it with delta tracking.
        return new Writer(input, chunkSize, ops).write();
    }

    /** The bitstream writer; mirrors {@link Compressor}'s mechanics. */
    private static final class Writer {
        private final byte[] input;
        private final int chunkSize;
        private final List<Op> ops;
        private byte[] output = new byte[0];
        private int outputIndex;
        private int inputIndex;
        private int bitIndex;
        private int bitMask;
        private int diff;
        private int delta;
        private boolean counting;
        private int bitCount;

        Writer(byte[] input, int chunkSize, List<Op> ops) {
            this.input = input;
            this.chunkSize = chunkSize;
            this.ops = ops;
        }

        Result write() {
            counting = true;
            emitAll();
            int outputSize = (bitCount + 7) / 8;
            counting = false;
            output = new byte[outputSize];
            outputIndex = 0;
            inputIndex = 0;
            bitMask = 0;
            diff = outputSize - input.length;
            delta = 0;
            emitAll();
            return new Result(output, delta);
        }

        private void emitAll() {
            int pos = 0;
            boolean firstBlock = true;
            boolean prevWasLiterals = false;
            for (Op op : ops) {
                boolean atBoundary = pos > 0 && pos % chunkSize == 0;
                if (op.offset() == 0) {                       // literals
                    if (firstBlock) {
                        firstBlock = false;                   // no leading bit
                    } else {
                        writeBit(false);                      // boundary code 0 and the
                    }                                         // in-chunk transition agree
                    writeEliasGamma(op.length());
                    for (int i = 0; i < op.length(); i++) {
                        writeByte(input[inputIndex]);
                        readBytes(1);
                    }
                    prevWasLiterals = true;
                } else if (op.offset() == -2) {               // full-chunk from-last
                    assert atBoundary && !firstBlock;
                    writeBit(true);                           // boundary code 11:
                    writeBit(true);                           // length implied, no gamma
                    readBytes(op.length());
                    prevWasLiterals = false;
                } else if (op.offset() == -1) {               // from-last match
                    assert (prevWasLiterals || atBoundary) && !firstBlock;
                    if (atBoundary) {
                        writeBit(true);                       // boundary code 100
                        writeBit(false);
                        writeBit(false);
                    } else {
                        writeBit(false);                      // after-literals: 0
                    }
                    writeEliasGamma(op.length());
                    readBytes(op.length());
                    prevWasLiterals = false;
                } else {                                      // new-offset match
                    assert !firstBlock;
                    writeBit(true);                           // boundary code 101, or the
                    if (atBoundary) {                         // in-chunk transition 1
                        writeBit(false);
                        writeBit(true);
                    }
                    writeOffset(op.offset());
                    writeEliasGamma(op.length() - 1);
                    readBytes(op.length());
                    prevWasLiterals = false;
                }
                pos += op.length();
            }
            writeBit(true);                                   // end marker: transition 1
            if (pos % chunkSize == 0) {                       ; // or boundary code 101
                writeBit(false);
                writeBit(true);
            }
            writeByte(255);
            writeByte(255);
        }

        private void writeOffset(int offset) {
            if (offset > 128) {
                writeByte(255 - ((offset - 1) & 254));
                writeByte(252 - (offset - 1) / 256 * 2 + offset % 2);
            } else {
                writeByte(256 - offset * 2);
            }
        }

        private void readBytes(int n) {
            inputIndex += n;
            diff += n;
            if (delta < diff) {
                delta = diff;
            }
        }

        private void writeByte(int value) {
            if (counting) {
                bitCount += 8;
                return;
            }
            output[outputIndex++] = (byte) value;
            diff--;
        }

        private void writeBit(boolean value) {
            if (counting) {
                bitCount++;
                return;
            }
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

        private void writeEliasGamma(int value) {
            for (int i = Integer.highestOneBit(value) >> 1; i != 0; i >>= 1) {
                writeBit(true);
                writeBit((value & i) != 0);
            }
            writeBit(false);
        }
    }

    /** Minimal CLI for the emulation harness: input output chunkSize [offsetLimit]. */
    public static void main(String[] args) throws IOException {
        byte[] input = Files.readAllBytes(Path.of(args[0]));
        int chunkSize = Integer.parseInt(args[2]);
        int offsetLimit = args.length > 3 ? Integer.parseInt(args[3]) : Zx1.MAX_OFFSET_ZX1;
        Result result = compress(input, chunkSize, offsetLimit);
        Files.write(Path.of(args[1]), result.output());
        System.out.printf("File chunk-compressed from %d to %d bytes! (chunk %d, delta %d)%n",
                input.length, result.output().length, chunkSize, result.delta());
    }
}
