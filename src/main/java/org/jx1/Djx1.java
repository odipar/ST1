package org.jx1;

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Command-line ZX1 decompressor. Java port of {@code dzx1.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Djx1 {

    private Djx1() {}

    public static void main(String[] args) {
        System.out.println("DJX1: Data decompressor v1.0 by Robbert van Dalen, "
                + "based on DZX1 v1.5: Data decompressor by Einar Saukas");

        // Process hidden optional parameters.
        boolean forcedMode = false;
        int bufferSize = Decompressor.DEFAULT_BUFFER_SIZE;
        int i = 0;
        for (; i < args.length && args[i].startsWith("-"); i++) {
            if (args[i].equals("-f")) {
                forcedMode = true;
            } else if (args[i].startsWith("-m")) {
                bufferSize = Cli.parseNumber(args[i].substring(2));
                if (bufferSize <= 0) {
                    throw Cli.error("Invalid parameter " + args[i]);
                }
            } else {
                throw Cli.error("Invalid parameter " + args[i]);
            }
        }

        // Determine output filename.
        String inputName;
        String outputName;
        if (args.length == i + 1) {
            inputName = args[i];
            if (inputName.length() > 4 && inputName.endsWith(".zx1")) {
                outputName = inputName.substring(0, inputName.length() - 4);
            } else {
                throw Cli.error("Cannot infer output filename");
            }
        } else if (args.length == i + 2) {
            inputName = args[i];
            outputName = args[i + 1];
        } else {
            Cli.usage("""
                    Usage: djx1 [-f] [-mN] input.zx1 [output]
                      -f      Force overwrite of output file
                      -mN     Ring buffer of N bytes (default 65536); N must cover the largest offset""");
            return;
        }

        // Read input file.
        byte[] input;
        try {
            input = Files.readAllBytes(Path.of(inputName));
        } catch (IOException e) {
            throw Cli.error("Cannot access input file " + inputName);
        }
        if (input.length == 0) {
            throw Cli.error("Empty input file " + inputName);
        }

        // Check output file.
        Path outputPath = Path.of(outputName);
        if (!forcedMode && Files.exists(outputPath)) {
            throw Cli.error("Already existing output file " + outputName);
        }

        // Decompress, streaming each buffer flip straight to the output file like the C original.
        try (var output = new BufferedOutputStream(Files.newOutputStream(outputPath))) {
            new Decompressor(input, new byte[bufferSize]) {
                @Override
                protected void flip(byte[] buffer, int length) {
                    try {
                        output.write(buffer, 0, length);
                    } catch (IOException e) {
                        throw new UncheckedIOException(e);
                    }
                }
            }.decompress();
        } catch (IOException | UncheckedIOException e) {
            throw Cli.error("Cannot write output file " + outputName);
        } catch (AssertionError e) {
            // With -ea, malformed input trips a descriptive assertion; report it like the C tool.
            throw Cli.error(e.getMessage() + " " + inputName);
        }

        // Done!
        try {
            System.out.printf("File decompressed from %d to %d bytes!%n", input.length, Files.size(outputPath));
        } catch (IOException e) {
            throw Cli.error("Cannot write output file " + outputName);
        }
    }
}
