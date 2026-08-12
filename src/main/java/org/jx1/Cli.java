package org.jx1;

/** Shared helpers for the command-line entry points. */
final class Cli {

    private Cli() {}

    /** Prints an error and exits; declared to return so callers can {@code throw} it for flow analysis. */
    static RuntimeException error(String message) {
        System.err.println("Error: " + message);
        System.exit(1);
        throw new AssertionError("unreachable");
    }

    static void usage(String text) {
        System.err.println(text);
        System.exit(1);
    }

    /** Parses a numeric argument; anything invalid becomes 0, so callers reject it like C rejects {@code atoi} <= 0. */
    static int parseNumber(String arg) {
        try {
            return Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
