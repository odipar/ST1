package org.yx6;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Random;

/** Builds synthetic YM5!/YM6! dumps, so the tests need no distributable tune. */
final class Ym6TestData {

    private Ym6TestData() {}

    /**
     * A tune whose registers behave like real chip data: tones that hold for a
     * while and step, volumes that decay, an envelope shape that is mostly
     * "unchanged", and effect bits set in the registers that carry them - so
     * masking has something to remove.
     */
    static byte[][] registers(int frames) {
        var random = new Random(1234);
        byte[][] values = new byte[Ym6Reader.Song.YM_REGISTERS][frames];
        int[] period = {0, 0, 0};
        int[] volume = {15, 12, 9};
        for (int frame = 0; frame < frames; frame++) {
            for (int voice = 0; voice < 3; voice++) {
                if (frame % (7 + voice * 3) == 0) {
                    period[voice] = 40 + random.nextInt(3000);
                    volume[voice] = 15;
                } else if (volume[voice] > 0 && frame % 4 == 0) {
                    volume[voice]--;
                }
                values[voice * 2][frame] = (byte) (period[voice] & 0xFF);
                values[voice * 2 + 1][frame] = (byte) (period[voice] >> 8);
                values[8 + voice][frame] = (byte) volume[voice];
            }
            values[6][frame] = (byte) (frame % 32);                 // noise period
            values[7][frame] = (byte) (0x38 | (frame % 8));         // mixer
            values[11][frame] = (byte) (frame * 3);                 // envelope period
            values[12][frame] = (byte) (frame / 64);
            values[13][frame] = (byte) (frame % 50 == 0 ? 0x0A : 0xFF);

            // YM6 effect bits, in exactly the places the format puts them: the
            // top nibbles of R1/R3, the top bits of R6/R7 and of the volumes,
            // and R14/R15 as effect data. None of it is chip state.
            values[1][frame] |= (byte) 0x30;
            values[3][frame] |= (byte) 0xC0;
            values[6][frame] |= (byte) 0xE0;
            values[7][frame] |= (byte) 0xC0;
            values[8][frame] |= (byte) 0x20;
            values[9][frame] |= (byte) 0x40;
            values[10][frame] |= (byte) 0x80;
            values[14][frame] = (byte) random.nextInt(256);
            values[15][frame] = (byte) random.nextInt(256);
        }
        return values;
    }

    static byte[] file(byte[][] registers, int frames, boolean interleaved) {
        return file(registers, frames, interleaved, "YM6!", 50, 0, 0);
    }

    static byte[] file(byte[][] registers, int frames, boolean interleaved, String format,
                       int playerHz, int digidrums, int loopFrame) {
        var out = new ByteArrayOutputStream();
        out.writeBytes(format.getBytes(StandardCharsets.US_ASCII));
        out.writeBytes("LeOnArD!".getBytes(StandardCharsets.US_ASCII));
        writeLong(out, frames);
        writeLong(out, interleaved ? 1 : 0);
        writeWord(out, digidrums);
        writeLong(out, 2000000);                        // master clock
        writeWord(out, playerHz);
        writeLong(out, loopFrame);
        writeWord(out, 4);                              // additional data size
        out.writeBytes(new byte[4]);
        for (int i = 0; i < digidrums; i++) {
            writeLong(out, 3);
            out.writeBytes(new byte[] {1, 2, 3});
        }
        writeString(out, "Test Tune");
        writeString(out, "Nobody");
        writeString(out, "Synthetic");

        if (interleaved) {
            for (byte[] vector : registers) {
                out.write(vector, 0, frames);
            }
        } else {
            for (int frame = 0; frame < frames; frame++) {
                for (byte[] vector : registers) {
                    out.write(vector[frame]);
                }
            }
        }
        out.writeBytes("End!".getBytes(StandardCharsets.US_ASCII));
        return out.toByteArray();
    }

    private static void writeString(ByteArrayOutputStream out, String text) {
        out.writeBytes(text.getBytes(StandardCharsets.US_ASCII));
        out.write(0);
    }

    private static void writeWord(ByteArrayOutputStream out, int value) {
        out.write(value >>> 8);
        out.write(value);
    }

    private static void writeLong(ByteArrayOutputStream out, int value) {
        writeWord(out, value >>> 16);
        writeWord(out, value);
    }
}
