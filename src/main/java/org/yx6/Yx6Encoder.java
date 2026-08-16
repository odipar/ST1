package org.yx6;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.jx1.Compressor;
import org.jx1.Jx1;
import org.jx1.Optimizer;

/**
 * Turns a parsed YM tune into a {@code .yx6} file: fourteen register vectors,
 * masked down to what a plain YM2149 sees, each packed as its own ZX1 stream.
 *
 * <p>Packing the registers separately is the whole point. A register's value
 * usually repeats from frame to frame, and a vector holds one register's values
 * back to back, so the matches are short-range and dense. It also gives the
 * player fourteen independent decoders it can advance one at a time, which is
 * what keeps the per-VBL cost flat.
 *
 * <p>A looping tune is packed as two sets of streams, split at the loop frame.
 * Looping means restarting a decoder, and a ZX1 stream can only be restarted
 * from its beginning - so the frames from the loop point on become streams of
 * their own, which the player re-inits every time round. The split costs a
 * little ratio, since the loop half cannot reference the intro half, and costs
 * nothing at all for the common case of a tune that loops from frame 0.
 *
 * <p>Each stream is packed the way {@link org.jx1.Jx1} would with
 * {@code -mN -l65535}: offsets never reach further back than the ring the
 * player decodes through, and no single operation is longer than the word
 * counters in the 68000 decoder.
 */
public final class Yx6Encoder {

    /** What packing one register vector produced. */
    public record Stream(int register, boolean loop, int frames, int packedSize, int longestOp) {}

    /** The finished file plus the per-stream numbers the CLI reports. */
    public record Result(byte[] file, List<Stream> streams, int ringSize, int chunk,
                         int loopFrame, boolean loops) {

        public int packedSize() {
            return streams.stream().mapToInt(Stream::packedSize).sum();
        }

        /** The longest operation in any stream; over 65535 the file is unsafe for ST1. */
        public int longestOp() {
            return streams.stream().mapToInt(Stream::longestOp).max().orElse(0);
        }
    }

    private Yx6Encoder() {}

    /** Packs a tune that plays once and stops. */
    public static Result encode(Ym6Reader.Song song, int ringSize, int chunk) {
        return encode(song, ringSize, chunk, -1);
    }

    /**
     * Packs a tune, looping at {@code loopFrame} - or playing once and stopping
     * when {@code loopFrame} is negative. A loop frame of 0 means the whole
     * tune is the loop.
     */
    public static Result encode(Ym6Reader.Song song, int ringSize, int chunk, int loopFrame) {
        String problem = Yx6Format.checkShape(ringSize, chunk);
        if (!problem.isEmpty()) {
            throw new IllegalArgumentException(problem);
        }
        boolean loops = loopFrame >= 0;
        if (loops && loopFrame >= song.frames()) {
            throw new IllegalArgumentException("loop frame " + loopFrame
                    + " is not inside a tune of " + song.frames() + " frames");
        }
        // Without a loop the intro covers everything, which is the same thing
        // as looping at the end - so the player needs only one rule.
        int split = loops ? loopFrame : song.frames();

        // A back-reference may never reach out of the ring the player decodes
        // through, and the format's own ceiling still applies above that.
        int offsetLimit = Math.min(ringSize, Jx1.MAX_OFFSET_ZX1);

        var streams = new ArrayList<Stream>(2 * Yx6Format.STREAMS);
        var intro = new byte[Yx6Format.STREAMS][];
        var loop = new byte[Yx6Format.STREAMS][];
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            byte[] values = Ym2149.mask(register, song.registers()[register]);
            intro[register] = pack(streams, register, false,
                    Arrays.copyOfRange(values, 0, split), offsetLimit);
            loop[register] = pack(streams, register, true,
                    loops ? Arrays.copyOfRange(values, split, values.length) : new byte[0],
                    offsetLimit);
        }

        byte[] file = build(song, ringSize, chunk, split, loops, intro, loop);
        return new Result(file, List.copyOf(streams), ringSize, chunk, split, loops);
    }

    /** Packs one section of one register; an empty section produces no stream. */
    private static byte[] pack(List<Stream> streams, int register, boolean loop,
                               byte[] values, int offsetLimit) {
        if (values.length == 0) {
            return new byte[0];
        }
        Compressor.Result result = Compressor.compress(
                Optimizer.optimize(values, 0, offsetLimit), values, 0, false, Jx1.MAX_OP_ST1);
        streams.add(new Stream(register, loop, values.length, result.output().length,
                result.longestOp()));
        return result.output();
    }

    private static byte[] build(Ym6Reader.Song song, int ringSize, int chunk, int split,
                                boolean loops, byte[][] intro, byte[][] loop) {
        int total = Yx6Format.HEADER_SIZE;
        for (byte[] stream : intro) {
            total += stream.length;
        }
        for (byte[] stream : loop) {
            total += stream.length;
        }

        byte[] file = new byte[total];
        putLong(file, Yx6Format.OFFSET_MAGIC, Yx6Format.MAGIC);
        putWord(file, Yx6Format.OFFSET_VERSION, Yx6Format.VERSION);
        putWord(file, Yx6Format.OFFSET_FLAGS, loops ? Yx6Format.FLAG_LOOPS : 0);
        putLong(file, Yx6Format.OFFSET_FRAMES, song.frames());
        putWord(file, Yx6Format.OFFSET_PLAYER_HZ, song.playerHz());
        putWord(file, Yx6Format.OFFSET_STREAM_COUNT, Yx6Format.STREAMS);
        putWord(file, Yx6Format.OFFSET_RING_SIZE, ringSize);
        putWord(file, Yx6Format.OFFSET_CHUNK, chunk);
        putLong(file, Yx6Format.OFFSET_LOOP_FRAME, split);
        putLong(file, Yx6Format.OFFSET_MASTER_CLOCK, song.masterClock());

        int at = Yx6Format.HEADER_SIZE;
        at = place(file, Yx6Format.OFFSET_INTRO_TABLE, intro, at);
        place(file, Yx6Format.OFFSET_LOOP_TABLE, loop, at);
        return file;
    }

    /** Copies one table's streams into the file and fills in its offsets. */
    private static int place(byte[] file, int table, byte[][] streams, int at) {
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            if (streams[register].length == 0) {
                continue;                       // no such section: the offset stays 0
            }
            putLong(file, table + 4 * register, at);
            System.arraycopy(streams[register], 0, file, at, streams[register].length);
            at += streams[register].length;
        }
        return at;
    }

    private static void putWord(byte[] file, int at, int value) {
        file[at] = (byte) (value >>> 8);
        file[at + 1] = (byte) value;
    }

    private static void putLong(byte[] file, int at, long value) {
        putWord(file, at, (int) (value >>> 16));
        putWord(file, at + 2, (int) value);
    }
}
