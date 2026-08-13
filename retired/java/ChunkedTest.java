package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.junit.jupiter.api.Test;

final class ChunkedTest {

    private static List<byte[]> inputs() {
        byte[] random = new byte[3000];
        new Random(7).nextBytes(random);
        byte[] allSame = new byte[1000];
        Arrays.fill(allSame, (byte) 'A');
        return List.of(new byte[] {42}, new byte[] {1, 1}, random, allSame,
                TestData.text(), TestData.farMatch(), TestData.wordSoup());
    }

    @Test
    void roundTripsAtVariousChunkSizes() {
        for (byte[] input : inputs()) {
            for (int chunk : new int[] {8, 16, 32, 127}) {
                byte[] compressed = CompressorChunked.compress(input, chunk, Zx1.MAX_OFFSET_ZX1).output();
                assertArrayEquals(input, DecompressorChunked.decompress(compressed, chunk),
                        "chunk " + chunk);
            }
        }
    }

    @Test
    void resumeEmitsExactlyOneChunkPerCall() {
        byte[] input = new byte[360];                 // offset-1 data: a 1-byte ring
        Arrays.fill(input, (byte) 'A');               // observes per-call emission
        byte[] compressed = CompressorChunked.compress(input, 16, 1).output();
        var output = new ByteArrayOutputStream();
        var d = new DecompressorChunked(compressed, new byte[1], 16) {
            @Override
            protected void flip(byte[] buffer, int length) {
                output.write(buffer, 0, length);
            }
        };
        int calls = 0;
        int previous = 0;
        while (d.resume()) {
            calls++;
            int emitted = output.size() - previous;
            assertTrue(emitted == 16 || output.size() == input.length,
                    "call " + calls + " emitted " + emitted);
            previous = output.size();
        }
        assertArrayEquals(input, output.toByteArray());
        assertEquals(input.length / 16, calls);
    }

    /** The 68k bare bit reads rely on refills striking only gamma continuation bits. */
    @Test
    void refillInvariantHoldsForTheChunkedGrammar() {
        for (byte[] input : inputs()) {
            for (int chunk : new int[] {8, 16, 32}) {
                byte[] compressed = CompressorChunked.compress(input, chunk, Zx1.MAX_OFFSET_ZX1).output();
                new InvariantReader(compressed, chunk, input.length).check();
            }
        }
    }

    /** Re-decodes tracking every bit read's role; asserts refills only on continuations. */
    private static final class InvariantReader {
        private final byte[] input;
        private final int chunkSize;
        private final int total;
        private int inputIndex;
        private int bitMask;
        private int bitValue;

        InvariantReader(byte[] input, int chunkSize, int total) {
            this.input = input;
            this.chunkSize = chunkSize;
            this.total = total;
        }

        int bit(boolean continuation) {
            bitMask >>= 1;
            if (bitMask == 0) {
                bitMask = 128;
                bitValue = input[inputIndex++] & 255;
                assertTrue(continuation, "refill outside a gamma continuation bit");
            }
            return (bitValue & bitMask) != 0 ? 1 : 0;
        }

        int gamma() {
            int value = 1;
            while (bit(true) == 1) {
                value = value << 1 | bit(false);
            }
            return value;
        }

        void check() {
            long produced = 0;
            boolean first = true;
            while (true) {
                if (!first && produced == total) {        // end at an exact boundary
                    assertEquals(1, bit(false));
                    assertEquals(0, bit(true));           // end is always code 101
                    assertEquals(1, bit(false));
                    assertTrue(!offset());
                    return;
                }
                int budget = chunkSize;    // the real decoder never knows the total
                boolean literalsNext = true;
                if (first) {
                    first = false;
                } else if (bit(false) == 1) {             // boundary: 0 / 11 / 100 / 101
                    if (bit(true) == 1) {                 // middle bit: refill-checked;
                        produced += budget;               // 11 = full-chunk from-last,
                        continue;                         // implied length
                    }
                    if (bit(false) == 1) {
                        literalsNext = false;             // 101: new-offset opens
                    } else {                              // 100: from-last opens
                        int len = gamma();
                        produced += len;
                        budget -= len;
                        if (budget == 0) {
                            continue;
                        }
                        literalsNext = bit(false) == 0;
                    }
                }
                while (true) {
                    int len;
                    if (literalsNext) {
                        len = gamma();
                        inputIndex += len;                // literal bytes
                        produced += len;
                        budget -= len;
                        if (budget == 0) {
                            break;
                        }
                        if (bit(false) == 1) {
                            assertTrue(offset() || produced == total);
                            if (produced == total) {
                                return;                   // end marker mid-chunk
                            }
                            len = gamma() + 1;
                        } else {
                            len = gamma();                // from-last
                        }
                    } else {
                        assertTrue(offset() || produced == total);
                        if (produced == total) {
                            return;
                        }
                        len = gamma() + 1;
                    }
                    produced += len;
                    budget -= len;
                    if (budget == 0) {
                        break;
                    }
                    literalsNext = bit(false) == 0;
                }
            }
        }

        private boolean offset() {                            // false = end marker
            int low = input[inputIndex++] & 255;
            if ((low & 1) != 0) {
                int high = input[inputIndex++] & 255;
                return 32512 - (high & 254) * 128 - (low & 254) - (high & 1) > 0;
            }
            return true;
        }
    }

    @Test
    void ratioCostIsBounded() {
        for (byte[] input : List.of(TestData.text(), TestData.wordSoup(), TestData.farMatch())) {
            int standard = Compressor.compress(
                    Optimizer.optimize(input, 0, Zx1.MAX_OFFSET_ZX1), input, 0, false).output().length;
            int chunked = CompressorChunked.compress(input, 16, Zx1.MAX_OFFSET_ZX1).output().length;
            assertTrue(chunked < input.length, "chunked must still compress");
            System.out.printf("ratio: standard %d, chunked16 %d (%.1f%% larger)%n",
                    standard, chunked, 100.0 * (chunked - standard) / standard);
        }
    }
}
