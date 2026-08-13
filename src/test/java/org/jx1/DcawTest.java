package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

final class DcawTest {

    private static byte[] compress(byte[] input, int lambda) {
        return Compressor.compress(
                OptimizerDcaw.optimize(input, 0, Zx1.MAX_OFFSET_ZX1, lambda), input, 0, false).output();
    }

    @Test
    void lambdaZeroMatchesTheBitOptimalSize() {
        for (byte[] input : List.of(TestData.text(), TestData.wordSoup(), TestData.farMatch())) {
            int standard = Compressor.compress(
                    Optimizer.optimize(input, 0, Zx1.MAX_OFFSET_ZX1), input, 0, false).output().length;
            assertEquals(standard, compress(input, 0).length);
        }
    }

    @Test
    void allLambdasRoundTripThroughEveryDecoderPath() {
        for (byte[] input : List.of(TestData.text(), TestData.wordSoup(), TestData.farMatch())) {
            for (int lambda : new int[] {0, 4, 16, 64}) {
                byte[] compressed = compress(input, lambda);
                assertArrayEquals(input, Decompressor.decompress(compressed));
            }
        }
    }

    @Test
    void ratioDegradesMonotonicallyWithLambda() {
        for (byte[] input : List.of(TestData.text(), TestData.wordSoup(), TestData.farMatch())) {
            int previous = 0;
            for (int lambda : new int[] {0, 4, 16, 64}) {
                int size = compress(input, lambda).length;
                assertTrue(size >= previous, "size must not shrink as lambda grows");
                previous = size;
            }
        }
    }
}
