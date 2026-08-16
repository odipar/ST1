package org.yx6;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Command-line YM to yx6 packer: reads a YM5!/YM6! register dump and writes a
 * {@code .yx6} file that the 68000 {@code YX6.S} player streams through ST1.
 *
 * <p>Version 0.1 plays the fourteen standard YM2149 registers. The YM6 special
 * effects - SID voice, digidrum, sinus-SID, sync-buzzer - are dropped, along
 * with the register bits that carry them.
 */
public final class Yx6 {

    private Yx6() {}

    public static void main(String[] args) {
        System.out.println("YX6: YM chiptune packer v0.1 by Robbert van Dalen, "
                + "streaming ZX1 through ST1");

        int ringSize = Yx6Format.DEFAULT_RING_SIZE;
        int chunk = Yx6Format.DEFAULT_CHUNK;
        boolean forcedMode = false;
        int i = 0;
        for (; i < args.length && args[i].startsWith("-"); i++) {
            switch (args[i]) {
                case "-f" -> forcedMode = true;
                default -> {
                    if (args[i].startsWith("-n")) {
                        ringSize = parseNumber(args[i].substring(2));
                    } else if (args[i].startsWith("-c")) {
                        chunk = parseNumber(args[i].substring(2));
                    } else {
                        throw error("Invalid parameter " + args[i]);
                    }
                }
            }
        }

        String outputName;
        if (args.length == i + 1) {
            outputName = args[i] + ".yx6";
        } else if (args.length == i + 2) {
            outputName = args[i + 1];
        } else {
            usage("""
                    Usage: yx6 [-f] [-nN] [-cC] input.ym [output.yx6]
                      -f      Force overwrite of output file
                      -nN     Ring size per register, in bytes (default 1024)
                      -cC     Values decoded per call, and the round-robin group
                              size (default 16; needs C >= 14 and N mod C = 0)

                    The input is an unpacked YM5!/YM6! dump. Distributed .ym files
                    are LHA archives: unpack one first with `lha x song.ym`.""");
            return;
        }
        String inputName = args[i];

        String problem = Yx6Format.checkShape(ringSize, chunk);
        if (!problem.isEmpty()) {
            throw error(problem);
        }

        byte[] input;
        try {
            input = Files.readAllBytes(Path.of(inputName));
        } catch (IOException e) {
            throw error("Cannot access input file " + inputName);
        }

        Path outputPath = Path.of(outputName);
        if (!forcedMode && Files.exists(outputPath)) {
            throw error("Already existing output file " + outputName);
        }

        Ym6Reader.Song song;
        try {
            song = Ym6Reader.read(input);
        } catch (Ym6Reader.FormatException e) {
            throw error(inputName + ": " + e.getMessage());
        }

        Yx6Encoder.Result result = Yx6Encoder.encode(song, ringSize, chunk);
        try {
            Files.write(outputPath, result.file());
        } catch (IOException e) {
            throw error("Cannot write output file " + outputName);
        }

        report(song, result);
    }

    private static void report(Ym6Reader.Song song, Yx6Encoder.Result result) {
        System.out.printf("%s: %s%s%s%n", song.format(),
                song.name().isBlank() ? "(untitled)" : song.name(),
                song.author().isBlank() ? "" : " by " + song.author(),
                song.interleaved() ? "" : " (de-interleaved)");
        if (song.digidrums() > 0) {
            System.out.printf("Warning: %d digidrum sample%s dropped; v0.1 plays no effects%n",
                    song.digidrums(), song.digidrums() == 1 ? "" : "s");
        }

        int raw = song.frames() * Yx6Format.STREAMS;
        System.out.printf("%d frames at %d Hz (%d:%02d), %d rings of %d bytes, %d per call%n",
                song.frames(), song.playerHz(),
                song.frames() / song.playerHz() / 60, song.frames() / song.playerHz() % 60,
                Yx6Format.STREAMS, result.ringSize(), result.chunk());
        for (Yx6Encoder.Stream stream : result.streams()) {
            System.out.printf("  R%-2d %6d -> %6d bytes (%5.1f%%)%n", stream.register(),
                    stream.frames(), stream.packedSize(),
                    100.0 * stream.packedSize() / stream.frames());
        }
        System.out.printf("Packed %d register bytes into %d (%.1f%%), file %d bytes%n",
                raw, result.packedSize(), 100.0 * result.packedSize() / raw, result.file().length);
        System.out.printf("Player needs %d bytes of ring plus its state%n",
                Yx6Format.STREAMS * result.ringSize());

        if (result.longestOp() > 65535) {
            // A literal run, the one operation ZX1 cannot split. Only a tune
            // longer than 65535 frames with a register that never repeats can
            // reach this, and the 68000 decoder would mis-decode it.
            System.out.printf("Warning: longest operation is %d bytes, over the 65535 the "
                    + "68000 decoder can represent: do not play this file with ST1%n",
                    result.longestOp());
        }
    }

    private static RuntimeException error(String message) {
        System.err.println("Error: " + message);
        System.exit(1);
        throw new AssertionError("unreachable");
    }

    private static void usage(String text) {
        System.err.println(text);
        System.exit(1);
    }

    private static int parseNumber(String argument) {
        try {
            int value = Integer.parseInt(argument);
            if (value <= 0) {
                throw error("Invalid parameter value " + argument);
            }
            return value;
        } catch (NumberFormatException e) {
            throw error("Invalid parameter value " + argument);
        }
    }
}
