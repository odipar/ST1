package org.yx6;

/**
 * The {@code .yx6} container: a fixed header followed by one ZX1 stream per
 * YM2149 sound register.
 *
 * <p>Every field is big-endian, which is what the 68000 player reads directly
 * out of the loaded file. The header is a fixed size so the player can index
 * the stream table without parsing anything.
 *
 * <pre>
 *   0   4  'YX6!'
 *   4   2  format version (1)
 *   6   2  flags (0 in v0.1)
 *   8   4  O, the number of frames - the output size of every stream
 *  12   2  player frequency in Hz (50 for a standard ST tune)
 *  14   2  S, the stream count (14: R0..R13)
 *  16   2  N, the ring size in bytes each stream decodes through
 *  18   2  C, the chunk size one ST1_resume call produces
 *  20   4  loop frame, informational in v0.1
 *  24   4  YM master clock in Hz, informational
 *  28   4*S  byte offset of each packed stream from the start of the file
 *  84   ...  the packed streams, in register order
 * </pre>
 *
 * <p>The player needs {@code O}, {@code N}, {@code C} and the offsets; the
 * packed sizes are implied by the next offset and never needed, because
 * ST1_wrap counts output bytes rather than input bytes.
 */
public final class Yx6Format {

    /** {@code 'YX6!'}, the first four bytes of every file. */
    public static final int MAGIC = 0x59583621;

    /** The only version this release writes or reads. */
    public static final int VERSION = 1;

    /** R0..R13: the YM2149 sound registers. R14/R15 are I/O ports, never played. */
    public static final int STREAMS = 14;

    public static final int OFFSET_MAGIC = 0;
    public static final int OFFSET_VERSION = 4;
    public static final int OFFSET_FLAGS = 6;
    public static final int OFFSET_FRAMES = 8;
    public static final int OFFSET_PLAYER_HZ = 12;
    public static final int OFFSET_STREAM_COUNT = 14;
    public static final int OFFSET_RING_SIZE = 16;
    public static final int OFFSET_CHUNK = 18;
    public static final int OFFSET_LOOP_FRAME = 20;
    public static final int OFFSET_MASTER_CLOCK = 24;
    public static final int OFFSET_STREAM_TABLE = 28;

    public static final int HEADER_SIZE = OFFSET_STREAM_TABLE + 4 * STREAMS;

    /** Default ring size: the size the ST1 timings in the README are quoted for. */
    public static final int DEFAULT_RING_SIZE = 1024;

    /**
     * Default chunk size, and the group size the round-robin player is built
     * around: one refill per VBL covers all {@value #STREAMS} registers within
     * a 16-VBL cycle, with two VBLs to spare.
     */
    public static final int DEFAULT_CHUNK = 16;

    private Yx6Format() {}

    /**
     * Checks a ring/chunk pair against what both the format and the player
     * require, and returns the reason it is unusable, or null when it is fine.
     *
     * <p>{@code N mod C = 0} is ST1_wrap's own rule. {@code C >= S} is the
     * player's: the refill schedule gives each register one VBL of its own
     * inside a group. {@code N >= 2C} keeps the group being read and the group
     * being written from sharing ring space.
     */
    public static String checkShape(int ringSize, int chunk) {
        if (chunk < STREAMS) {
            return "chunk " + chunk + " is below the " + STREAMS
                    + " streams, so the round-robin refill cannot fit in one cycle";
        }
        if (ringSize < 2 * chunk) {
            return "ring " + ringSize + " must hold two chunks of " + chunk;
        }
        if (ringSize % chunk != 0) {
            return "ring " + ringSize + " is not a multiple of chunk " + chunk;
        }
        if (ringSize > 65535) {
            return "ring " + ringSize + " exceeds the 65535-byte ST1 limit";
        }
        return "";
    }
}
