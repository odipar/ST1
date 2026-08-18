package org.yx6;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Arrays;
import org.jx1.Decompressor;
import org.junit.jupiter.api.Test;

/** The loop split: two sets of streams, and what the player is promised. */
final class Yx6LoopTest {

    private static final int FRAMES = 900;

    private static Ym6Reader.Song song(int loopFrame) {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        return Ym6Reader.read(Ym6TestData.file(registers, FRAMES, true, "YM6!", 50, 0, loopFrame));
    }

    private static int word(byte[] file, int at) {
        return ((file[at] & 0xFF) << 8) | (file[at + 1] & 0xFF);
    }

    private static int longAt(byte[] file, int at) {
        return (word(file, at) << 16) | word(file, at + 2);
    }

    private static byte[] stream(byte[] file, int table, int register, int packedSize) {
        int from = longAt(file, table + 4 * register);
        return Decompressor.decompress(Arrays.copyOfRange(file, from, from + packedSize));
    }

    private static int packedSize(Yx6Encoder.Result result, int register, boolean loop) {
        return result.streams().stream()
                .filter(s -> s.register() == register && s.loop() == loop)
                .findFirst().orElseThrow().packedSize();
    }

    @Test
    void eachSectionUnpacksToItsOwnSliceOfTheRegister() {
        int split = 397;                            // not a multiple of the chunk
        Ym6Reader.Song source = song(split);
        Yx6Encoder.Result result = Yx6Encoder.encode(source, 1024, 16, split, false);
        byte[] file = result.file();

        assertEquals(Yx6Format.FLAG_LOOPS, word(file, Yx6Format.OFFSET_FLAGS));
        assertEquals(split, longAt(file, Yx6Format.OFFSET_LOOP_FRAME));

        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            byte[] whole = Ym2149.mask(register, source.registers()[register]);
            assertArrayEquals(Arrays.copyOfRange(whole, 0, split),
                    stream(file, Yx6Format.OFFSET_INTRO_TABLE, register,
                            packedSize(result, register, false)),
                    "intro stream " + register);
            assertArrayEquals(Arrays.copyOfRange(whole, split, whole.length),
                    stream(file, Yx6Format.OFFSET_LOOP_TABLE, register,
                            packedSize(result, register, true)),
                    "loop stream " + register);
        }
    }

    @Test
    void loopingFromTheStartPacksNoIntro() {
        Yx6Encoder.Result result = Yx6Encoder.encode(song(0), 1024, 16, 0, false);
        byte[] file = result.file();

        assertEquals(0, longAt(file, Yx6Format.OFFSET_LOOP_FRAME));
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            assertEquals(0, longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register),
                    "intro offset " + register + " should be unused");
            assertTrue(longAt(file, Yx6Format.OFFSET_LOOP_TABLE + 4 * register) > 0);
        }
        assertEquals(Yx6Format.STREAMS, result.streams().size());
    }

    @Test
    void playingOncePacksNoLoop() {
        Yx6Encoder.Result result = Yx6Encoder.encode(song(0), 1024, 16, -1, false);
        byte[] file = result.file();

        assertEquals(0, word(file, Yx6Format.OFFSET_FLAGS));
        assertEquals(FRAMES, longAt(file, Yx6Format.OFFSET_LOOP_FRAME),
                "the intro covers everything, so the split sits at the end");
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            assertTrue(longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register) > 0);
            assertEquals(0, longAt(file, Yx6Format.OFFSET_LOOP_TABLE + 4 * register),
                    "loop offset " + register + " should be unused");
        }
    }

    @Test
    void theSplitCostsRatioButLoopingFromZeroDoesNot() {
        int whole = Yx6Encoder.encode(song(0), 1024, 16, -1, false).packedSize();
        int fromStart = Yx6Encoder.encode(song(0), 1024, 16, 0, false).packedSize();
        int fromMiddle = Yx6Encoder.encode(song(450), 1024, 16, 450, false).packedSize();

        assertEquals(whole, fromStart, "one section either way, so the same bytes");
        assertTrue(fromMiddle > whole, "splitting a register costs some ratio");
    }

    @Test
    void rejectsALoopFrameOutsideTheTune() {
        Ym6Reader.Song source = song(0);
        assertThrows(IllegalArgumentException.class,
                () -> Yx6Encoder.encode(source, 1024, 16, FRAMES, false));
        assertThrows(IllegalArgumentException.class,
                () -> Yx6Encoder.encode(source, 1024, 16, FRAMES + 10, false));
    }

    @Test
    void bothSectionsStayInsideTheRingAndTheWordCounters() {
        int ring = 256;
        Yx6Encoder.Result result = Yx6Encoder.encode(song(397), ring, 16, 397, false);
        byte[] file = result.file();
        assertTrue(result.longestOp() <= 65535);

        for (Yx6Encoder.Stream stream : result.streams()) {
            int table = stream.loop() ? Yx6Format.OFFSET_LOOP_TABLE
                    : Yx6Format.OFFSET_INTRO_TABLE;
            int from = longAt(file, table + 4 * stream.register());
            byte[] packed = Arrays.copyOfRange(file, from, from + stream.packedSize());
            assertEquals(stream.frames(),
                    Decompressor.decompress(packed, new byte[ring]).length,
                    "stream " + stream.register() + (stream.loop() ? " loop" : " intro")
                            + " needs more than a " + ring + "-byte ring");
        }
    }

    @Test
    void theLoopFrameComesFromTheYmHeaderUnlessOverridden() {
        // What the CLI reads: a YM6 file carries its own loop frame.
        assertEquals(397, song(397).loopFrame());
        assertNotEquals(397, Yx6Encoder.encode(song(397), 1024, 16, 0, false).loopFrame());
    }
}
