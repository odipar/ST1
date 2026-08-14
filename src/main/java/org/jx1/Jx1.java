package org.jx1;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Command-line ZX1 compressor. Java port of {@code zx1.c} from
 * <a href="https://github.com/einar-saukas/ZX1">ZX1</a> by Einar Saukas.
 */
public final class Jx1 {

    public static final int MAX_OFFSET_ZX1 = 32512;
    public static final int MAX_OFFSET_ZX7 = 2176;

    /**
     * The longest operation the 68000 decoders can represent: they hold an
     * operation's remaining length in a word. A stream containing a longer
     * operation is still valid here and decodes correctly in Java, but decodes
     * to the wrong length on a 68000, so {@code -l65535} is what makes a stream
     * safe for them.
     */
    public static final int MAX_OP_68K = 65535;

    private Jx1() {}

    public static void main(String[] args) {
        System.out.println("JX1: Optimal data compressor v0.1 by Robbert van Dalen, "
                + "based on ZX1 v1.5: Optimal data compressor by Einar Saukas");

        // Process optional parameters.
        int skip = 0;
        int maxOffset = 0;
        int maxOpLength = Integer.MAX_VALUE;
        boolean forcedMode = false;
        boolean quickMode = false;
        boolean backwardsMode = false;
        int i = 0;
        for (; i < args.length && (args[i].startsWith("-") || args[i].startsWith("+")); i++) {
            switch (args[i]) {
                case "-f" -> forcedMode = true;
                case "-b" -> backwardsMode = true;
                case "-q" -> quickMode = true;
                default -> {
                    if (args[i].startsWith("-m")) {
                        maxOffset = Cli.parseNumber(args[i].substring(2));
                        if (maxOffset <= 0) {
                            throw Cli.error("Invalid parameter " + args[i]);
                        }
                    } else if (args[i].startsWith("-l")) {
                        maxOpLength = Cli.parseNumber(args[i].substring(2));
                        if (maxOpLength <= 0) {
                            throw Cli.error("Invalid parameter " + args[i]);
                        }
                    } else {
                        skip = Cli.parseNumber(args[i]);
                        if (skip <= 0) {
                            throw Cli.error("Invalid parameter " + args[i]);
                        }
                    }
                }
            }
        }
        if (maxOffset > MAX_OFFSET_ZX1 - (backwardsMode ? 1 : 0)) {
            throw Cli.error("Invalid parameter -m" + maxOffset);
        }

        // Determine output filename.
        String outputName;
        if (args.length == i + 1) {
            outputName = args[i] + ".zx1";
        } else if (args.length == i + 2) {
            outputName = args[i + 1];
        } else {
            Cli.usage("""
                    Usage: jx1 [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
                      -f      Force overwrite of output file
                      -b      Compress backwards
                      -q      Quick non-optimal compression
                      -mN     Limit backreference offsets to N bytes
                      -lN     Split matches so no operation exceeds N bytes
                              (use -l65535 for the 68000 decoders)""");
            return;
        }
        String inputName = args[i];

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

        // Validate skip against input size.
        if (skip >= input.length) {
            throw Cli.error("Skipping entire input file " + inputName);
        }

        // Check output file.
        Path outputPath = Path.of(outputName);
        if (!forcedMode && Files.exists(outputPath)) {
            throw Cli.error("Already existing output file " + outputName);
        }

        // Conditionally reverse input, compress, conditionally reverse output.
        if (backwardsMode) {
            reverse(input);
        }
        int offsetLimit = maxOffset > 0 ? maxOffset
                : quickMode ? MAX_OFFSET_ZX7 : MAX_OFFSET_ZX1 - (backwardsMode ? 1 : 0);
        Compressor.Result result = Compressor.compress(
                Optimizer.optimize(input, skip, offsetLimit), input, skip, backwardsMode, maxOpLength);
        byte[] output = result.output();
        if (backwardsMode) {
            reverse(output);
        }

        // Write output file.
        try {
            Files.write(outputPath, output);
        } catch (IOException e) {
            throw Cli.error("Cannot write output file " + outputName);
        }

        // Done!
        System.out.printf("File%s compressed%s from %d to %d bytes! (delta %d)%n",
                skip != 0 ? " partially" : "", backwardsMode ? " backwards" : "",
                input.length - skip, output.length, result.delta());
        if (result.longestOp() > maxOpLength) {
            // Only a literal run can get here - matches are split - and only
            // from data with no matches to break the run on. The format has no
            // way to say "more literals", so this is reported, not fixed.
            System.out.printf("Warning: longest operation is %d bytes, over the -l%d limit: "
                    + "a literal run, which the format cannot split%n",
                    result.longestOp(), maxOpLength);
        }
    }

    private static void reverse(byte[] data) {
        for (int first = 0, last = data.length - 1; first < last; first++, last--) {
            byte c = data[first];
            data[first] = data[last];
            data[last] = c;
        }
    }
}
