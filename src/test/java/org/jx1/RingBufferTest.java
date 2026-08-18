package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

final class RingBufferTest {

    private static byte[] compress(byte[] input, int offsetLimit) {
        return Compressor.compress(Optimizer.optimize(input, 0, offsetLimit, false), input, 0, false).output();
    }

    @Test
    void roundTripsThroughSmallRingBuffers() {
        for (byte[] input : List.of(TestData.text(), TestData.wordSoup())) {
            byte[] compressed = compress(input, 511);
            for (int bufferSize : new int[] {511, 512, 600, 65536}) {
                assertArrayEquals(input, Decompressor.decompress(compressed, new byte[bufferSize]));
            }
        }
    }

    @Test
    void flipsDeliverFullBuffersThenTheRemainder() {
        byte[] input = TestData.text();
        byte[] compressed = compress(input, 100);
        var flips = new ArrayList<Integer>();
        var output = new ByteArrayOutputStream();
        new Decompressor(compressed, new byte[100]) {
            @Override
            protected void flip(byte[] buffer, int length) {
                flips.add(length);
                output.write(buffer, 0, length);
            }
        }.decompress();

        assertArrayEquals(input, output.toByteArray());
        assertEquals(input.length / 100 + 1, flips.size());
        for (int j = 0; j < flips.size() - 1; j++) {
            assertEquals(100, flips.get(j));
        }
        assertEquals(input.length % 100, flips.getLast());
    }

    @Test
    void supportsOffsetsUpToExactlyTheBufferSize() {
        // Period-300 data parses as matches at offset 300 (verified below), the buffer's exact size.
        byte[] period = new byte[300];
        new java.util.Random(9).nextBytes(period);
        byte[] input = new byte[1500];
        for (int j = 0; j < input.length; j++) {
            input[j] = period[j % 300];
        }
        byte[] compressed = compress(input, 300);
        assertArrayEquals(input, Decompressor.decompress(compressed, new byte[300]));
        assertThrows(AssertionError.class,
                () -> Decompressor.decompress(compressed, new byte[299]));
    }

    @Test
    void rejectsBackreferenceBeyondBufferSize() {
        // farMatch contains an offset of ~2700, far beyond a 512-byte ring.
        byte[] compressed = compress(TestData.farMatch(), Jx1.MAX_OFFSET_ZX1);
        AssertionError e = assertThrows(AssertionError.class,
                () -> Decompressor.decompress(compressed, new byte[512]));
        assertTrue(String.valueOf(e.getMessage()).startsWith("Backreference beyond ring buffer"));
    }

    @Test
    void rleCopiesWrapAcrossTheBufferBoundary() {
        byte[] input = new byte[1000];
        Arrays.fill(input, (byte) 'A');
        byte[] compressed = compress(input, 64);
        assertArrayEquals(input, Decompressor.decompress(compressed, new byte[64]));
    }

    @Test
    void decompressorInstancesAreReusable() {
        byte[] input = TestData.text();
        byte[] compressed = compress(input, 511);
        var output = new ByteArrayOutputStream();
        var decompressor = new Decompressor(compressed, new byte[512]) {
            @Override
            protected void flip(byte[] buffer, int length) {
                output.write(buffer, 0, length);
            }
        };
        decompressor.decompress();
        decompressor.decompress();
        assertEquals(2 * input.length, output.size());
        assertArrayEquals(input, Arrays.copyOfRange(output.toByteArray(), input.length, 2 * input.length));
    }

    @Test
    void rejectsEmptyBuffer() {
        assertThrows(AssertionError.class,
                () -> Decompressor.decompress(compress(TestData.text(), 511), new byte[0]));
    }
}
