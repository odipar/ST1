package org.jx1;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.HexFormat;
import org.junit.jupiter.api.Test;

/**
 * Pins the exact bitstream against reference vectors produced by the original C implementation
 * (zx1 v1.5, compiled from c/zx1/src).
 */
final class GoldenTest {

    private static Compressor.Result compress(byte[] input, int skip, int offsetLimit, boolean backwards) {
        return Compressor.compress(Optimizer.optimize(input, skip, offsetLimit), input, skip, backwards);
    }

    private static void assertGolden(String expectedHex, int expectedDelta, Compressor.Result actual) {
        assertArrayEquals(HexFormat.of().parseHex(expectedHex), actual.output());
        assertEquals(expectedDelta, actual.delta());
    }

    @Test
    void text() {
        assertGolden("f761627261636164f22a6920686f6375732070f4d0bdb8baaf40ffff", 2,
                compress(TestData.text(), 0, Jx1.MAX_OFFSET_ZX1, false));
    }

    @Test
    void textWithSkip() {
        assertGolden("dc636164f2a920686f6375732070f4a6d0f6b8eabdffff", 2,
                compress(TestData.text(), 4, Jx1.MAX_OFFSET_ZX1, false));
    }

    @Test
    void textBackwards() {
        // Mirrors the -b mode of the CLI: reverse input, compress backwards, reverse output.
        byte[] input = TestData.text();
        reverse(input);
        Compressor.Result result = compress(input, 0, Jx1.MAX_OFFSET_ZX1 - 1, true);
        reverse(result.output());
        assertGolden("0001d0ab466e2e686f0a706f6375732068ce0c6361646162726120a9", 2, result);
    }

    @Test
    void farMatch() {
        assertGolden("ebac73d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9be"
                + "f76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4ef"
                + "3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01dcc"
                + "eb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a560"
                + "17e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b887b"
                + "b478afeabd75e8eafdffff", 2,
                compress(TestData.farMatch(), 0, Jx1.MAX_OFFSET_ZX1, false));
    }

    @Test
    void farMatchQuickMode() {
        // The far match at offset ~2700 exceeds the ZX7 limit, so the block repeats as literals.
        assertGolden("ebac73d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9be"
                + "f76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4ef"
                + "3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01dcc"
                + "eb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a560"
                + "17e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b887b"
                + "b478afeabceba973d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9"
                + "bef76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4"
                + "ef3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01d"
                + "cceb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a5"
                + "6017e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b88"
                + "7bb4ffff", 4,
                compress(TestData.farMatch(), 0, Jx1.MAX_OFFSET_ZX7, false));
    }

    @Test
    void wordSoup() {
        Compressor.Result result = compress(TestData.wordSoup(), 0, Jx1.MAX_OFFSET_ZX1, false);
        assertEquals(777, result.output().length);
        assertEquals(2, result.delta());
        assertArrayEquals(TestData.wordSoup(), Decompressor.decompress(result.output()));
    }

    private static void reverse(byte[] data) {
        for (int first = 0, last = data.length - 1; first < last; first++, last--) {
            byte c = data[first];
            data[first] = data[last];
            data[last] = c;
        }
    }
}
