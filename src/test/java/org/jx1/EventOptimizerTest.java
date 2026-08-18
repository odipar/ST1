package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.junit.jupiter.api.Test;

/**
 * {@link EventOptimizer} against {@link FastOptimizer}: the optimum is unique,
 * so the engine's cost array must equal the DP's element for element - the
 * strongest check an optimizer that breaks ties differently can be held to.
 * Its chains must decompress back to the input, and compress to within the one
 * byte a different split of control bits against whole bytes can round
 * differently. The skip axis matters here: the engine handles skip with a
 * special case at skip+1 that these shapes are chosen to reach.
 */
final class EventOptimizerTest {

    private static List<byte[]> inputs() {
        byte[] random = new byte[4096];
        new Random(7).nextBytes(random);
        byte[] sparse = new byte[4096];
        var r = new Random(11);
        for (int i = 0; i < sparse.length; i++) {
            sparse[i] = (byte) (r.nextInt(4) * 17 + i % 3);
        }
        byte[] allSame = new byte[3000];
        Arrays.fill(allSame, (byte) 'A');
        byte[] period = new byte[4096];
        for (int i = 0; i < period.length; i++) {
            period[i] = (byte) (i % 3);
        }
        byte[] lone = new byte[2048];
        r = new Random(3);
        for (int i = 0; i < lone.length; i++) {
            lone[i] = (byte) r.nextInt(256);
        }
        System.arraycopy(lone, 0, lone, 1500, 300);
        return List.of(new byte[] {42}, new byte[] {1, 2, 3}, new byte[] {7, 7},
                random, sparse, allSame, period, lone,
                "abracadabra hocus pocus ".repeat(40).getBytes(
                        java.nio.charset.StandardCharsets.US_ASCII));
    }

    @Test
    void computesTheExactSameCosts() {
        for (byte[] input : inputs()) {
            for (int window : new int[] {16, 128, 1024, Jx1.MAX_OFFSET_ZX1}) {
                for (int skip : new int[] {0, 1, 5}) {
                    if (skip >= input.length) {
                        continue;
                    }
                    int[] reference = FastOptimizer.costs(input, skip, window);
                    int[] engine = EventOptimizer.costs(input, skip, window);
                    assertArrayEquals(
                            Arrays.copyOfRange(reference, skip, reference.length),
                            Arrays.copyOfRange(engine, skip, engine.length),
                            input.length + " bytes, m=" + window + ", skip=" + skip);
                }
            }
        }
    }

    @Test
    void itsChainsRoundTripAtTheSameSize() {
        for (byte[] input : inputs()) {
            for (int window : new int[] {128, Jx1.MAX_OFFSET_ZX1}) {
                byte[] packed = Compressor.compress(
                        EventOptimizer.optimize(input, 0, window, false),
                        input, 0, false).output();
                assertArrayEquals(input, Decompressor.decompress(packed),
                        input.length + " bytes, m=" + window);
                byte[] reference = Compressor.compress(
                        FastOptimizer.optimize(input, 0, window, false),
                        input, 0, false).output();
                assertTrue(Math.abs(packed.length - reference.length) <= 1,
                        input.length + " bytes, m=" + window + ": "
                                + packed.length + " vs " + reference.length);
            }
        }
    }
}
