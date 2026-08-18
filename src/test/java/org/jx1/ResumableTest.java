package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import org.junit.jupiter.api.Test;

final class ResumableTest {

    private static byte[] compress(byte[] input, int offsetLimit) {
        return Compressor.compress(Optimizer.optimize(input, 0, offsetLimit, false), input, 0, false).output();
    }

    private static final class Collector extends Decompressor {
        final ByteArrayOutputStream output = new ByteArrayOutputStream();

        Collector(byte[] input, byte[] buffer, int chunkSize) {
            super(input, buffer, chunkSize);
        }

        @Override
        protected void flip(byte[] buffer, int length) {
            output.write(buffer, 0, length);
        }
    }

    @Test
    void resumeCallCountMatchesChunkSize() {
        byte[] input = TestData.text();
        byte[] compressed = compress(input, 511);
        for (int chunkSize : new int[] {1, 7, 100, 359, 360, 361, 10000}) {
            var collector = new Collector(compressed, new byte[512], chunkSize);
            int calls = 1;
            while (collector.resume()) {
                calls++;
            }
            assertEquals(Math.ceilDiv(input.length, chunkSize), calls);
            assertArrayEquals(input, collector.output.toByteArray());
            assertFalse(collector.resume());
        }
    }

    @Test
    void eachResumeEmitsAtMostOneChunk() {
        // A 1-byte ring flips on every output byte, making per-call emission observable.
        byte[] input = new byte[1000];
        Arrays.fill(input, (byte) 'A');
        byte[] compressed = compress(input, 1);
        var collector = new Collector(compressed, new byte[1], 64);
        int previousSize = 0;
        while (collector.resume()) {
            assertEquals(64, collector.output.size() - previousSize);
            previousSize = collector.output.size();
        }
        assertEquals(1000, collector.output.size());
        assertArrayEquals(input, collector.output.toByteArray());
    }

    @Test
    void resumingInterleavesWithRingFlips() {
        byte[] input = TestData.wordSoup();
        byte[] compressed = compress(input, 100);
        var collector = new Collector(compressed, new byte[100], 37);
        while (collector.resume()) {}
        assertArrayEquals(input, collector.output.toByteArray());
    }

    @Test
    void rejectsOverflowedGammaLengthImmediately() {
        // One literal 'A', then a last-offset match whose Elias-gamma has 31 continuation bits,
        // overflowing to a negative length. Must trip the assert at once instead of wrapping
        // `remaining` through the whole int range and emitting ~2^31 garbage bytes.
        byte[] malformed = {0x2a, 0x41, (byte) 0xaa, (byte) 0xaa, (byte) 0xaa, (byte) 0xaa,
                (byte) 0xaa, (byte) 0xaa, (byte) 0xaa, 0x00};
        var collector = new Collector(malformed, new byte[512], 100);
        assertThrows(AssertionError.class, collector::decompress);
        assertEquals(0, collector.output.size());
    }

    @Test
    void resumeAfterCompletedDecompressReturnsFalse() {
        byte[] input = TestData.text();
        var collector = new Collector(compress(input, 511), new byte[512], 100);
        collector.decompress();
        assertArrayEquals(input, collector.output.toByteArray());
        assertFalse(collector.resume());
    }
}
