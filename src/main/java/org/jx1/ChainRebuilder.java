package org.jx1;

import java.util.ArrayDeque;
import java.util.HashMap;
import org.jspecify.annotations.Nullable;

/**
 * Rebuilds an optimal parse chain from what a forward cost pass recorded: the
 * winning cost per position and a three-int descriptor of the winning
 * candidate - its kind, its offset, and the one value that cannot be
 * recomputed later. Everything else is re-derived on demand from those costs
 * and the data itself, so only the blocks the winning chain actually contains
 * are ever built.
 *
 * <p>Both {@link FastOptimizer} and {@link EventOptimizer} feed this class.
 * Their descriptors may name different winners where candidates tie - any
 * winner a forward pass records rebuilds to a chain of exactly the recorded
 * cost - so the chains may differ between them while the total cost cannot.
 */
final class ChainRebuilder {

    private static final int NONE = Integer.MIN_VALUE;

    /** Winner kinds: a literal run, a match reusing the offset, a new offset. */
    static final byte LITERALS = 1;
    static final byte REP = 2;
    static final byte NEW = 3;

    private final byte[] input;
    private final int skip;
    private final int[] optimalBits;
    private final byte[] winKind;
    private final int[] winOffset;
    private final int[] winAux;

    ChainRebuilder(byte[] input, int skip, int[] optimalBits,
                   byte[] winKind, int[] winOffset, int[] winAux) {
        this.input = input;
        this.skip = skip;
        this.optimalBits = optimalBits;
        this.winKind = winKind;
        this.winOffset = winOffset;
        this.winAux = winAux;
    }

    private static int eliasGammaBits(int value) {
        return 2 * (31 - Integer.numberOfLeadingZeros(value)) + 1;
    }

    /** Does the DP's match branch run at this position and offset? */
    private boolean matches(int index, int offset) {
        return index != skip && index >= offset && input[index] == input[index - offset];
    }


    /**
     * A pending resolution: the winner chain at an index, or the state an
     * offset held when it last matched there. Frames form a chain of single
     * dependencies, resolved with an explicit stack because a chain of
     * one-byte blocks is as deep as the input is long.
     */
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

    Block rebuild() {
        int last = input.length - 1;
        var winner = new @Nullable Block[input.length];
        var states = new HashMap<Long, Block>();
        states.put(stateKey(Optimizer.INITIAL_OFFSET, skip - 1),
                new Block(-1, skip - 1, Optimizer.INITIAL_OFFSET, null));

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
                if (offset == Optimizer.INITIAL_OFFSET || matches(index - 1, offset)) {
                    return lastMatch;
                }
            }
        }
        return offset == Optimizer.INITIAL_OFFSET ? skip - 1 : NONE;
    }
}
