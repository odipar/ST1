package org.yx6;

import java.util.ArrayList;
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
 * <p>Each stream is packed the way {@link org.jx1.Jx1} would with
 * {@code -mN -l65535}: offsets never reach further back than the ring the
 * player decodes through, and no single operation is longer than the word
 * counters in the 68000 decoder.
 */
public final class Yx6Encoder {

    /** What packing one register vector produced. */
    public record Stream(int register, int frames, int packedSize, int longestOp) {}

    /** The finished file plus the per-stream numbers the CLI reports. */
    public record Result(byte[] file, List<Stream> streams, int ringSize, int chunk) {

        public int packedSize() {
            return streams.stream().mapToInt(Stream::packedSize).sum();
        }

        /** The longest operation in any stream; over 65535 the file is unsafe for ST1. */
        public int longestOp() {
            return streams.stream().mapToInt(Stream::longestOp).max().orElse(0);
        }
    }

    private Yx6Encoder() {}

    public static Result encode(Ym6Reader.Song song, int ringSize, int chunk) {
        String problem = Yx6Format.checkShape(ringSize, chunk);
        if (!problem.isEmpty()) {
            throw new IllegalArgumentException(problem);
        }

        // A back-reference may never reach out of the ring the player decodes
        // through, and the format's own ceiling still applies above that.
        int offsetLimit = Math.min(ringSize, Jx1.MAX_OFFSET_ZX1);

        var streams = new ArrayList<Stream>(Yx6Format.STREAMS);
        var packed = new byte[Yx6Format.STREAMS][];
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            byte[] values = Ym2149.mask(register, song.registers()[register]);
            Compressor.Result result = Compressor.compress(
                    Optimizer.optimize(values, 0, offsetLimit), values, 0, false, Jx1.MAX_OP_ST1);
            packed[register] = result.output();
            streams.add(new Stream(register, values.length, result.output().length,
                    result.longestOp()));
        }

        return new Result(build(song, ringSize, chunk, packed), List.copyOf(streams),
                ringSize, chunk);
    }

    private static byte[] build(Ym6Reader.Song song, int ringSize, int chunk, byte[][] packed) {
        int total = Yx6Format.HEADER_SIZE;
        for (byte[] stream : packed) {
            total += stream.length;
        }

        byte[] file = new byte[total];
        putLong(file, Yx6Format.OFFSET_MAGIC, Yx6Format.MAGIC);
        putWord(file, Yx6Format.OFFSET_VERSION, Yx6Format.VERSION);
        putWord(file, Yx6Format.OFFSET_FLAGS, 0);
        putLong(file, Yx6Format.OFFSET_FRAMES, song.frames());
        putWord(file, Yx6Format.OFFSET_PLAYER_HZ, song.playerHz());
        putWord(file, Yx6Format.OFFSET_STREAM_COUNT, Yx6Format.STREAMS);
        putWord(file, Yx6Format.OFFSET_RING_SIZE, ringSize);
        putWord(file, Yx6Format.OFFSET_CHUNK, chunk);
        putLong(file, Yx6Format.OFFSET_LOOP_FRAME, song.loopFrame());
        putLong(file, Yx6Format.OFFSET_MASTER_CLOCK, song.masterClock());

        int at = Yx6Format.HEADER_SIZE;
        for (int register = 0; register < Yx6Format.STREAMS; register++) {
            putLong(file, Yx6Format.OFFSET_STREAM_TABLE + 4 * register, at);
            System.arraycopy(packed[register], 0, file, at, packed[register].length);
            at += packed[register].length;
        }
        return file;
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
