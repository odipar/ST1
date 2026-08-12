package org.jx1;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Command-line ZX1 decompressor. Java port of {@code dzx1.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Dzx1 {

    private Dzx1() {}

    public static void main(String[] args) {
        System.out.println("DZX1 v1.5: Data decompressor by Einar Saukas");

        // Process hidden optional parameters.
        boolean forcedMode = false;
        int i = 0;
        for (; i < args.length && args[i].startsWith("-"); i++) {
            if (args[i].equals("-f")) {
                forcedMode = true;
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
                    Usage: dzx1 [-f] input.zx1 [output]
                      -f      Force overwrite of output file""");
            return;
        }

        // Read input file.
        byte[] input;
        try {
            input = Files.readAllBytes(Path.of(inputName));
        } catch (IOException e) {
            throw Cli.error("Cannot access input file " + inputName);
        }

        // Check output file.
        Path outputPath = Path.of(outputName);
        if (!forcedMode && Files.exists(outputPath)) {
            throw Cli.error("Already existing output file " + outputName);
        }

        // Decompress.
        byte[] output;
        try {
            output = Decompressor.decompress(input);
        } catch (IllegalArgumentException e) {
            throw Cli.error(e.getMessage() + " " + inputName);
        }

        // Write output file.
        try {
            Files.write(outputPath, output);
        } catch (IOException e) {
            throw Cli.error("Cannot write output file " + outputName);
        }

        // Done!
        System.out.printf("File decompressed from %d to %d bytes!%n", input.length, output.length);
    }
}
