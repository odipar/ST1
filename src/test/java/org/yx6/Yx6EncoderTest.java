package org.yx6;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Arrays;
import org.jx1.Decompressor;
import org.junit.jupiter.api.Test;

final class Yx6EncoderTest {

    private static final int FRAMES = 1500;

    private static Ym6Reader.Song song(boolean interleaved) {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        return Ym6Reader.read(Ym6TestData.file(registers, FRAMES, interleaved));
    }

    private static int word(byte[] file, int at) {
        return ((file[at] & 0xFF) << 8) | (file[at + 1] & 0xFF);
    }

    private static int longAt(byte[] file, int at) {
        return (word(file, at) << 16) | word(file, at + 2);
    }

    @Test
    void headerDescribesTheStreams() {
        Yx6Encoder.Result result = Yx6Encoder.encode(song(true), 1024, 16, false);
        byte[] file = result.file();

        assertEquals(Yx6Format.MAGIC, longAt(file, Yx6Format.OFFSET_MAGIC));
        assertEquals(Yx6Format.VERSION, word(file, Yx6Format.OFFSET_VERSION));
        assertEquals(0, word(file, Yx6Format.OFFSET_FLAGS), "a play-once tune does not loop");
        assertEquals(FRAMES, longAt(file, Yx6Format.OFFSET_LOOP_FRAME),
                "a play-once tune loops at its end");
        assertEquals(FRAMES, longAt(file, Yx6Format.OFFSET_FRAMES));
        assertEquals(50, word(file, Yx6Format.OFFSET_PLAYER_HZ));
        assertEquals(Yx6Format.STREAMS, word(file, Yx6Format.OFFSET_STREAM_COUNT));
        assertEquals(1024, word(file, Yx6Format.OFFSET_RING_SIZE));
        assertEquals(16, word(file, Yx6Format.OFFSET_CHUNK));

        // The table is in register order, gapless, and covers the whole file.
        int expected = Yx6Format.HEADER_SIZE;
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            assertEquals(expected, longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register),
                    "offset of stream " + register);
            expected += result.streams().get(register).packedSize();
        }
        assertEquals(file.length, expected);
    }

    @Test
    void everyStreamUnpacksToTheMaskedRegister() {
        Ym6Reader.Song source = song(true);
        Yx6Encoder.Result result = Yx6Encoder.encode(source, 1024, 16, false);
        byte[] file = result.file();

        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            int from = longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register);
            int to = from + result.streams().get(register).packedSize();
            byte[] unpacked = Decompressor.decompress(Arrays.copyOfRange(file, from, to));
            assertArrayEquals(Ym2149.mask(register, source.registers()[register]), unpacked,
                    "stream " + register + " does not decode to the masked register");
        }
    }

    @Test
    void interleavedAndPerFrameFilesPackIdentically() {
        assertArrayEquals(Yx6Encoder.encode(song(true), 1024, 16, false).file(),
                Yx6Encoder.encode(song(false), 1024, 16, false).file());
    }

    @Test
    void everyStreamSurvivesItsOwnRing() {
        // -mN is what makes a stream safe for an N-byte ring: decoding it
        // through exactly that ring must never need a byte that has left it.
        // A too-far offset does not fail loudly - it reads whatever the ring
        // has wrapped onto - so the output comparison is the check.
        Ym6Reader.Song source = song(true);
        for (int ring : new int[] {32, 256, 1024}) {
            Yx6Encoder.Result result = Yx6Encoder.encode(source, ring, 16, false);
            byte[] file = result.file();
            for (int register = 0; register < Yx6Format.STREAMS; register++) {
                int from = longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register);
                int to = from + result.streams().get(register).packedSize();
                assertArrayEquals(Ym2149.mask(register, source.registers()[register]),
                        Decompressor.decompress(Arrays.copyOfRange(file, from, to), new byte[ring]),
                        "stream " + register + " needs more than a " + ring + "-byte ring");
            }
        }
    }

    @Test
    void streamsDeliverTheChunksThePlayerAsksFor() {
        // The player's shape: C bytes per call, wrapping every N/C calls, with
        // exactly ceil(O/C) calls and a shorter final one. Java's resume() is
        // the same contract, so it can stand in for the 68000 caller here.
        Ym6Reader.Song source = song(true);
        int ring = 256;
        int chunk = 16;
        Yx6Encoder.Result result = Yx6Encoder.encode(source, ring, chunk, false);
        byte[] file = result.file();

        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            int from = longAt(file, Yx6Format.OFFSET_INTRO_TABLE + 4 * register);
            int to = from + result.streams().get(register).packedSize();
            var output = new java.io.ByteArrayOutputStream();
            var decoder = new Decompressor(Arrays.copyOfRange(file, from, to),
                    new byte[ring], chunk) {
                @Override
                protected void flip(byte[] buffer, int length) {
                    output.write(buffer, 0, length);
                }
            };
            int calls = 0;
            while (decoder.resume()) {
                calls++;
            }
            // The call that returns false is the one that finishes the stream
            // and flips the remainder, so it counts too.
            assertEquals((FRAMES + chunk - 1) / chunk, calls + 1,
                    "stream " + register + " took an unexpected number of calls");
            assertArrayEquals(Ym2149.mask(register, source.registers()[register]),
                    output.toByteArray(), "stream " + register + " through the player's shape");
        }
    }

    @Test
    void everyOperationFitsAWordCounter() {
        assertTrue(Yx6Encoder.encode(song(true), 1024, 16, false).longestOp() <= 65535);
    }

    @Test
    void rejectsShapesThePlayerCannotRun() {
        Ym6Reader.Song source = song(true);
        // Fewer values per call than registers: the round-robin cannot fit.
        assertThrows(IllegalArgumentException.class, () -> Yx6Encoder.encode(source, 1024, 13, false));
        // Ring smaller than two chunks: the group being written would land on
        // the group being read.
        assertThrows(IllegalArgumentException.class, () -> Yx6Encoder.encode(source, 16, 16, false));
        // ST1_wrap needs the chunk to divide the ring.
        assertThrows(IllegalArgumentException.class, () -> Yx6Encoder.encode(source, 1000, 16, false));
    }
}
