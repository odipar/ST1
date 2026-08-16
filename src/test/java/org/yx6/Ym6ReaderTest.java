package org.yx6;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.junit.jupiter.api.Test;

final class Ym6ReaderTest {

    private static final int FRAMES = 200;

    @Test
    void readsTheHeaderAndEveryRegisterVector() {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        Ym6Reader.Song song = Ym6Reader.read(Ym6TestData.file(registers, FRAMES, true));

        assertEquals("YM6!", song.format());
        assertEquals(FRAMES, song.frames());
        assertEquals(50, song.playerHz());
        assertEquals(2000000, song.masterClock());
        assertEquals("Test Tune", song.name());
        assertEquals("Nobody", song.author());
        assertEquals("Synthetic", song.comment());
        assertTrue(song.interleaved());
        for (int register = 0; register < Ym6Reader.Song.YM_REGISTERS; register++) {
            assertArrayEquals(registers[register], song.registers()[register],
                    "register " + register);
        }
    }

    @Test
    void perFrameFilesReadBackAsTheSameVectors() {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        Ym6Reader.Song interleaved = Ym6Reader.read(Ym6TestData.file(registers, FRAMES, true));
        Ym6Reader.Song perFrame = Ym6Reader.read(Ym6TestData.file(registers, FRAMES, false));

        assertTrue(interleaved.interleaved());
        assertEquals(false, perFrame.interleaved());
        for (int register = 0; register < Ym6Reader.Song.YM_REGISTERS; register++) {
            assertArrayEquals(interleaved.registers()[register], perFrame.registers()[register],
                    "register " + register);
        }
    }

    @Test
    void skipsDigidrumsAndAdditionalDataToFindTheFrames() {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        Ym6Reader.Song song = Ym6Reader.read(
                Ym6TestData.file(registers, FRAMES, true, "YM6!", 60, 3, 128));

        assertEquals(3, song.digidrums());
        assertEquals(128, song.loopFrame());
        assertEquals(60, song.playerHz());
        assertArrayEquals(registers[13], song.registers()[13]);
    }

    @Test
    void acceptsYm5() {
        byte[][] registers = Ym6TestData.registers(FRAMES);
        assertEquals("YM5!", Ym6Reader.read(
                Ym6TestData.file(registers, FRAMES, true, "YM5!", 50, 0, 0)).format());
    }

    @Test
    void namesTheProblemWithFilesItCannotRead() {
        byte[] lha = "..-lh5-junk".getBytes(StandardCharsets.US_ASCII);
        assertTrue(message(lha).contains("LHA archive"));

        byte[] ym3 = "YM3!and then some".getBytes(StandardCharsets.US_ASCII);
        assertTrue(message(ym3).contains("not a YM5!/YM6! file"));

        byte[][] registers = Ym6TestData.registers(FRAMES);
        byte[] good = Ym6TestData.file(registers, FRAMES, true);
        byte[] noCheckString = good.clone();
        noCheckString[4] = 'X';
        assertTrue(message(noCheckString).contains("LeOnArD!"));

        byte[] truncated = Arrays.copyOf(good, good.length / 2);
        assertTrue(message(truncated).contains("truncated"));
    }

    private static String message(byte[] file) {
        return String.valueOf(
                assertThrows(Ym6Reader.FormatException.class, () -> Ym6Reader.read(file))
                        .getMessage());
    }

    @Test
    void maskingDropsEffectBitsButKeepsTheEnvelopeMarker() {
        assertEquals(0x0A, Ym2149.mask(1, 0x3A));           // R1: 4-bit coarse tone
        assertEquals(0x1F, Ym2149.mask(6, 0xFF));           // R6: 5-bit noise period
        assertEquals(0x3F, Ym2149.mask(7, 0xFF));           // R7: mixer without the port bits
        assertEquals(0x1F, Ym2149.mask(8, 0xFF));           // R8: volume plus envelope mode
        assertEquals(0xFF, Ym2149.mask(9, 0xFF) | 0xE0);    // R9 keeps only its low five bits
        assertEquals(0xFF, Ym2149.mask(11, 0xFF));          // R11: full envelope period byte
        assertEquals(0xFF, Ym2149.mask(13, 0xFF));          // R13: "leave the envelope alone"
        assertEquals(0x0A, Ym2149.mask(13, 0x3A));          // R13: a real shape is four bits
    }
}
