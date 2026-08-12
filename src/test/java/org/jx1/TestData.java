package org.jx1;

import java.io.ByteArrayOutputStream;
import java.util.Random;

/** Deterministic sample inputs, shared by tests and the golden-vector generator. */
public final class TestData {

    private TestData() {}

    /** Repetitive text: 360 bytes. */
    public static byte[] text() {
        return "abracadabra hocus pocus abracadabra ".repeat(10).getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    }

    /** A far back-reference at offset ~2700, beyond the quick-mode (ZX7) limit of 2176. */
    public static byte[] farMatch() {
        var out = new ByteArrayOutputStream();
        byte[] block = new byte[200];
        new Random(1).nextBytes(block);
        out.writeBytes(block);
        out.writeBytes("x".repeat(2500).getBytes(java.nio.charset.StandardCharsets.US_ASCII));
        out.writeBytes(block);
        return out.toByteArray();
    }

    /** Pseudo-random word soup: mixed literals and nearby matches. */
    public static byte[] wordSoup() {
        var random = new Random(42);
        byte[][] words = new byte[20][];
        for (int i = 0; i < words.length; i++) {
            words[i] = new byte[3 + random.nextInt(7)];
            random.nextBytes(words[i]);
        }
        var out = new ByteArrayOutputStream();
        for (int i = 0; i < 400; i++) {
            out.writeBytes(words[random.nextInt(words.length)]);
            out.write(' ');
        }
        return out.toByteArray();
    }
}
