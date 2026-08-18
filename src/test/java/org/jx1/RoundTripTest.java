package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.junit.jupiter.api.Test;

final class RoundTripTest {

    private static byte[] compress(byte[] input) {
        return Compressor.compress(Optimizer.optimize(input, 0, Jx1.MAX_OFFSET_ZX1, false), input, 0, false).output();
    }

    @Test
    void roundTripsVariousInputs() {
        byte[] random = new byte[500];
        new Random(7).nextBytes(random);
        byte[] allSame = new byte[1000];
        Arrays.fill(allSame, (byte) 'A');
        byte[] alternating = new byte[64];
        for (int i = 0; i < alternating.length; i++) {
            alternating[i] = (byte) (i % 2);
        }

        for (byte[] input : List.of(new byte[] {42}, new byte[] {1, 1}, new byte[] {1, 2},
                random, allSame, alternating, TestData.text(), TestData.farMatch(), TestData.wordSoup())) {
            assertArrayEquals(input, Decompressor.decompress(compress(input)));
        }
    }

    @Test
    void quickModeRoundTrips() {
        byte[] input = TestData.farMatch();
        byte[] output = Compressor.compress(
                Optimizer.optimize(input, 0, Jx1.MAX_OFFSET_ZX7, false), input, 0, false).output();
        assertArrayEquals(input, Decompressor.decompress(output));
    }

    @Test
    void rejectsTruncatedInput() {
        byte[] compressed = compress(TestData.text());
        byte[] truncated = Arrays.copyOf(compressed, compressed.length - 2);
        assertThrows(AssertionError.class, () -> Decompressor.decompress(truncated));
    }

    @Test
    void rejectsTrailingGarbage() {
        byte[] compressed = compress(TestData.text());
        byte[] tooLong = Arrays.copyOf(compressed, compressed.length + 1);
        assertThrows(AssertionError.class, () -> Decompressor.decompress(tooLong));
    }

    @Test
    void rejectsInvalidBackReference() {
        // A back-reference into data that was never produced: literals(1)='A', then offset 2.
        assertThrows(AssertionError.class,
                () -> Decompressor.decompress(new byte[] {0b0100_0000, 'A', (byte) 252, 0}));
    }
}
