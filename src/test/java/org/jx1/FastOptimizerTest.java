package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;

import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.junit.jupiter.api.Test;

/**
 * {@link FastOptimizer} against {@link Optimizer}: the compressed output must
 * match byte for byte on every input shape, window and skip - the same
 * contract compat.py holds jx1 to against the original C compressor.
 */
final class FastOptimizerTest {

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
    void findsTheExactSameParse() {
        for (byte[] input : inputs()) {
            for (int window : new int[] {16, 128, 1024, Jx1.MAX_OFFSET_ZX1}) {
                for (int skip : new int[] {0, 1, 5}) {
                    if (skip >= input.length) {
                        continue;
                    }
                    byte[] reference = Compressor.compress(
                            Optimizer.optimize(input, skip, window, false),
                            input, skip, false).output();
                    byte[] fast = Compressor.compress(
                            FastOptimizer.optimize(input, skip, window, false),
                            input, skip, false).output();
                    assertArrayEquals(reference, fast,
                            input.length + " bytes, m=" + window + ", skip=" + skip);
                }
            }
        }
    }
}
