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
}
