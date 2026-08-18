package org.jx1;

import java.util.ArrayDeque;
import java.util.HashMap;
import org.jspecify.annotations.Nullable;

/**
 * {@link Optimizer}, restructured to not allocate: the same parse, found the
 * same way, producing byte-identical output - so {@code compat.py}'s
 * byte-for-byte comparison against the original C compressor holds for this
 * class exactly as it did for the original.
 *
 * <p>The original materialises every candidate as a {@link Block}, and nearly
 * all of them lose and become garbage - gigabytes of allocation per packed
 * asset. This version runs the identical DP forward on primitive arrays,
 * recording per position the winning cost and a three-int descriptor of the
 * winning candidate, then builds only the blocks the winning chain actually
 * contains by replaying each recorded decision backward from the descriptors,
 * the winning costs and the data itself. Candidates are evaluated in the same
 * order with the same strictly-better replacement rule, so ties fall exactly
 * as in the original. {@link Optimizer} stays in the tree as the specification
 * this class is checked against. It has a twin in the ST4 repository
 * (odipar/ST4, {@code St4FastOptimizer}) that differs only in the cost model:
 * one flag bit before an offset rather than three control bits, the byte form
 * reaching 128 rather than 512, and no {@code skip} parameter shifting where
 * the parse starts and where the fake block sits.
 */
public final class FastOptimizer {

    public static final int INITIAL_OFFSET = Optimizer.INITIAL_OFFSET;

    private static final int NONE = Integer.MIN_VALUE;

    /** Winner kinds: a literal run, a match reusing the offset, a new offset. */
    private static final byte LITERALS = 1;
    private static final byte REP = 2;
    private static final byte NEW = 3;

    private final byte[] input;
    private final int skip;
    private final int offsetLimit;

    /** Per position: the winning cost, and the descriptor to rebuild it. */
    private final int[] optimalBits;
    private final byte[] winKind;
    private final int[] winOffset;
    private final int[] winAux;

    private FastOptimizer(byte[] input, int skip, int offsetLimit) {
        this.input = input;
        this.skip = skip;
        this.offsetLimit = offsetLimit;
        this.optimalBits = new int[input.length];
        this.winKind = new byte[input.length];
        this.winOffset = new int[input.length];
        this.winAux = new int[input.length];
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input},
     * reporting progress on stdout while it works.
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit) {
        return optimize(input, skip, offsetLimit, true);
    }

    /**
     * Returns the last block of the optimal parse chain for {@code input} -
     * the same chain {@link Optimizer#optimize} returns, byte for byte.
     *
     * @param progress whether to report on stdout, as {@link ProgressMeter}
     */
    public static Block optimize(byte[] input, int skip, int offsetLimit,
                                 boolean progress) {
        var optimizer = new FastOptimizer(input, skip, offsetLimit);
        optimizer.forward(progress);
        return optimizer.reconstruct();
    }

    private static int eliasGammaBits(int value) {
        return 2 * (31 - Integer.numberOfLeadingZeros(value)) + 1;
    }

    /** Does the DP's match branch run at this position and offset? */
    private boolean matches(int index, int offset) {
        return index != skip && index >= offset && input[index] == input[index - offset];
    }

    // ------------------------------------------------------------- forward

    /**
     * The DP of {@link Optimizer#optimize}, candidate for candidate, on
     * primitives; see {@code St4FastOptimizer.forward} for the shape.
     */
    private void forward(boolean progress) {
        int count = input.length;
        int width = (int) Math.clamp(count - 1L, INITIAL_OFFSET, offsetLimit);
        int[] stateBits = new int[width + 1];
        int[] stateEnd = new int[width + 1];
        int[] litBits = new int[width + 1];
        int[] litEnd = new int[width + 1];
        int[] matchLength = new int[width + 1];
        java.util.Arrays.fill(stateEnd, NONE);
        java.util.Arrays.fill(litEnd, NONE);
        int[] bestLength = new int[Math.max(count, 3)];
        bestLength[2] = 2;

        // The fake block every chain hangs from, ending just before the start.
        stateBits[INITIAL_OFFSET] = -1;
        stateEnd[INITIAL_OFFSET] = skip - 1;

        var meter = new ProgressMeter(
                ProgressMeter.totalSteps(count, skip, offsetLimit), progress);

        for (int index = skip; index < count; index++) {
            int maxOffset = (int) Math.clamp((long) index, INITIAL_OFFSET, offsetLimit);
            int bestLengthSize = 2;
            byte value = input[index];
            int best = Integer.MAX_VALUE;
            for (int offset = 1; offset <= maxOffset; offset++) {
                if (index != skip && index >= offset && value == input[index - offset]) {
                    // Copy from last offset, after a literal run.
                    if (litEnd[offset] != NONE) {
                        int bits = litBits[offset] + 1
                                + eliasGammaBits(index - litEnd[offset]);
                        stateBits[offset] = bits;
                        stateEnd[offset] = index;
                        if (bits < best) {
                            best = bits;
                            winKind[index] = REP;
                            winOffset[index] = offset;
                            winAux[index] = litEnd[offset];
                        }
                    }
                    // Copy from a new offset, at the best split length.
                    if (++matchLength[offset] > 1) {
                        if (bestLengthSize < matchLength[offset]) {
                            int bits = optimalBits[index - bestLength[bestLengthSize]]
                                    + eliasGammaBits(bestLength[bestLengthSize] - 1);
                            do {
                                bestLengthSize++;
                                int shorterBits = optimalBits[index - bestLengthSize]
                                        + eliasGammaBits(bestLengthSize - 1);
                                if (shorterBits <= bits) {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = shorterBits;
                                } else {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            } while (bestLengthSize < matchLength[offset]);
                        }
                        int length = bestLength[matchLength[offset]];
                        int bits = optimalBits[index - length] + 1
                                + (offset > 128 ? 16 : 8)
                                + eliasGammaBits(length - 1);
                        if (stateEnd[offset] != index || stateBits[offset] > bits) {
                            stateBits[offset] = bits;
                            stateEnd[offset] = index;
                            if (bits < best) {
                                best = bits;
                                winKind[index] = NEW;
                                winOffset[index] = offset;
                                winAux[index] = length;
                            }
                        }
                    }
                } else {
                    // Literals, continuing from the offset's last match.
                    matchLength[offset] = 0;
                    if (stateEnd[offset] != NONE) {
                        int length = index - stateEnd[offset];
                        int bits = stateBits[offset] + 1 + eliasGammaBits(length)
                                + length * 8;
                        litBits[offset] = bits;
                        litEnd[offset] = index;
                        if (bits < best) {
                            best = bits;
                            winKind[index] = LITERALS;
                            winOffset[index] = offset;
                            winAux[index] = stateEnd[offset];
                        }
                    }
                }
            }
            assert best != Integer.MAX_VALUE : "every position has a winner";
            optimalBits[index] = best;
            meter.advance(maxOffset);
        }
        meter.finish();
    }

    // -------------------------------------------------------- reconstruction

    /** A pending resolution; see {@code St4FastOptimizer.Frame}. */
    private static final class Frame {
        final boolean isState;
        final int offset;
        final int index;
        boolean scanned;
        int runStart;
        int prevEnd = NONE;
        int newLength;
        int newBits;

        Frame(boolean isState, int offset, int index) {
            this.isState = isState;
            this.offset = offset;
            this.index = index;
        }
    }

    private Block reconstruct() {
        int last = input.length - 1;
        var winner = new @Nullable Block[input.length];
        var states = new HashMap<Long, Block>();
        states.put(stateKey(INITIAL_OFFSET, skip - 1),
                new Block(-1, skip - 1, INITIAL_OFFSET, null));

        var stack = new ArrayDeque<Frame>();
        stack.push(new Frame(false, 0, last));
        while (!stack.isEmpty()) {
            Frame frame = stack.peek();
            if (frame.isState ? resolveState(frame, states, winner, stack)
                              : resolveWinner(frame, states, winner, stack)) {
                stack.pop();
            }
        }
        Block block = winner[last];
        if (block == null) {
            throw new AssertionError("reconstruction did not reach the last position");
        }
        return block;
    }

    private static long stateKey(int offset, int index) {
        return (long) offset << 32 | (index & 0xFFFFFFFFL);
    }

    private boolean resolveWinner(Frame frame, HashMap<Long, Block> states,
                                  @Nullable Block[] winner, ArrayDeque<Frame> stack) {
        int index = frame.index;
        if (winner[index] != null) {
            return true;
        }
        int offset = winOffset[index];
        switch (winKind[index]) {
            case LITERALS -> {
                Block state = states.get(stateKey(offset, winAux[index]));
                if (state == null) {
                    stack.push(new Frame(true, offset, winAux[index]));
                    return false;
                }
                winner[index] = new Block(optimalBits[index], index, 0, state);
            }
            case REP -> {
                int litAt = winAux[index];
                int prevEnd = previousStateEnd(offset, litAt);
                Block state = states.get(stateKey(offset, prevEnd));
                if (state == null) {
                    stack.push(new Frame(true, offset, prevEnd));
                    return false;
                }
                winner[index] = new Block(optimalBits[index], index, offset,
                        literalRun(state, litAt));
            }
            case NEW -> {
                Block previous = winner[index - winAux[index]];
                if (previous == null) {
                    stack.push(new Frame(false, 0, index - winAux[index]));
                    return false;
                }
                winner[index] = new Block(optimalBits[index], index, offset, previous);
            }
            default -> throw new AssertionError("position " + index + " has no winner");
        }
        return true;
    }

    private boolean resolveState(Frame frame, HashMap<Long, Block> states,
                                 @Nullable Block[] winner, ArrayDeque<Frame> stack) {
        int offset = frame.offset;
        int end = frame.index;
        if (!frame.scanned) {
            frame.scanned = true;
            assert matches(end, offset) : "a state can only end on a match";
            int start = end;
            while (matches(start - 1, offset)) {
                start--;
            }
            frame.runStart = start;
            frame.prevEnd = previousStateEnd(offset, start - 1);
            int run = end - start + 1;
            if (run >= 2) {
                int bestCore = Integer.MAX_VALUE;
                for (int length = 2; length <= run; length++) {
                    int core = optimalBits[end - length] + eliasGammaBits(length - 1);
                    if (core <= bestCore) {          // ties go to the longer split
                        bestCore = core;
                        frame.newLength = length;
                    }
                }
                frame.newBits = bestCore + 1 + (offset > 128 ? 16 : 8);
            }
        }

        if (frame.prevEnd != NONE) {                 // the rep candidate exists
            Block previous = states.get(stateKey(offset, frame.prevEnd));
            if (previous == null) {
                stack.push(new Frame(true, offset, frame.prevEnd));
                return false;
            }
            Block literal = literalRun(previous, frame.runStart - 1);
            int repBits = literal.bits() + 1 + eliasGammaBits(end - frame.runStart + 1);
            if (frame.newLength == 0 || repBits <= frame.newBits) {
                states.put(stateKey(offset, end), new Block(repBits, end, offset, literal));
                return true;
            }
        }
        assert frame.newLength != 0 : "a state is a rep match or a new-offset match";
        Block previous = winner[end - frame.newLength];
        if (previous == null) {
            stack.push(new Frame(false, 0, end - frame.newLength));
            return false;
        }
        states.put(stateKey(offset, end), new Block(frame.newBits, end, offset, previous));
        return true;
    }

    /** The literal run from just after {@code state} through {@code litEnd}. */
    private Block literalRun(Block state, int litEnd) {
        int length = litEnd - state.index();
        int bits = state.bits() + 1 + eliasGammaBits(length) + length * 8;
        return new Block(bits, litEnd, 0, state);
    }

    /**
     * Where this offset's state ended at or before {@code from}, or NONE; see
     * {@code St4FastOptimizer.previousStateEnd}. Offset one's fallback is the
     * fake block just before the parse starts.
     */
    private int previousStateEnd(int offset, int from) {
        int lastMatch = NONE;
        for (int index = from; index > skip && index >= offset; index--) {
            if (input[index] == input[index - offset]) {
                if (lastMatch == NONE) {
                    lastMatch = index;
                }
                if (offset == INITIAL_OFFSET || matches(index - 1, offset)) {
                    return lastMatch;
                }
            }
        }
        return offset == INITIAL_OFFSET ? skip - 1 : NONE;
    }
}
