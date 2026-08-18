// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

namespace Nx1;

/// <summary>
/// Rebuilds an optimal parse chain from what a forward cost pass recorded: the
/// winning cost per position and a three-int descriptor of the winning
/// candidate - its kind, its offset, and the one value that cannot be
/// recomputed later. Everything else is re-derived on demand from those costs
/// and the data itself, so only the blocks the winning chain actually contains
/// are ever built.
/// </summary>
/// <remarks>
/// Both <see cref="FastOptimizer"/> and <see cref="EventOptimizer"/> feed this
/// class. Their descriptors may name different winners where candidates tie -
/// any winner a forward pass records rebuilds to a chain of exactly the
/// recorded cost - so the chains may differ between them while the total cost
/// cannot.
/// </remarks>
internal sealed class ChainRebuilder
{
    private const int None = int.MinValue;

    /// <summary>Winner kinds: a literal run, a match reusing the offset, a new offset.</summary>
    internal const byte Literals = 1;
    internal const byte Rep = 2;
    internal const byte New = 3;

    private readonly byte[] _input;
    private readonly int _skip;
    private readonly int[] _optimalBits;
    private readonly byte[] _winKind;
    private readonly int[] _winOffset;
    private readonly int[] _winAux;

    internal ChainRebuilder(byte[] input, int skip, int[] optimalBits,
                            byte[] winKind, int[] winOffset, int[] winAux)
    {
        _input = input;
        _skip = skip;
        _optimalBits = optimalBits;
        _winKind = winKind;
        _winOffset = winOffset;
        _winAux = winAux;
    }

    private static int EliasGammaBits(int value) =>
        2 * (31 - System.Numerics.BitOperations.LeadingZeroCount((uint)value)) + 1;

    /// <summary>Does the DP's match branch run at this position and offset?</summary>
    private bool Matches(int index, int offset) =>
        index != _skip && index >= offset && _input[index] == _input[index - offset];

    /// <summary>
    /// A pending resolution: the winner chain at an index, or the state an
    /// offset held when it last matched there. Frames form a chain of single
    /// dependencies, resolved with an explicit stack because a chain of
    /// one-byte blocks is as deep as the input is long.
    /// </summary>
    private sealed class Frame(bool isState, int offset, int index)
    {
        internal readonly bool IsState = isState;
        internal readonly int Offset = offset;
        internal readonly int Index = index;
        internal bool Scanned;
        internal int RunStart;
        internal int PrevEnd = None;
        internal int NewLength;
        internal int NewBits;
    }

    internal Block Rebuild()
    {
        int last = _input.Length - 1;
        var winner = new Block?[_input.Length];
        var states = new Dictionary<long, Block>
        {
            [StateKey(Optimizer.InitialOffset, _skip - 1)] =
                new Block(-1, _skip - 1, Optimizer.InitialOffset, null),
        };

        var stack = new Stack<Frame>();
        stack.Push(new Frame(false, 0, last));
        while (stack.Count > 0)
        {
            Frame frame = stack.Peek();
            if (frame.IsState ? ResolveState(frame, states, winner, stack)
                              : ResolveWinner(frame, states, winner, stack))
            {
                stack.Pop();
            }
        }
        return winner[last]
            ?? throw new InvalidOperationException("Reconstruction did not reach the last position");
    }

    private static long StateKey(int offset, int index) =>
        (long)offset << 32 | (index & 0xFFFFFFFFL);

    private bool ResolveWinner(Frame frame, Dictionary<long, Block> states,
                               Block?[] winner, Stack<Frame> stack)
    {
        int index = frame.Index;
        if (winner[index] is not null)
        {
            return true;
        }
        int offset = _winOffset[index];
        switch (_winKind[index])
        {
            case Literals:
            {
                if (!states.TryGetValue(StateKey(offset, _winAux[index]), out Block? state))
                {
                    stack.Push(new Frame(true, offset, _winAux[index]));
                    return false;
                }
                winner[index] = new Block(_optimalBits[index], index, 0, state);
                break;
            }
            case Rep:
            {
                int litAt = _winAux[index];
                int prevEnd = PreviousStateEnd(offset, litAt);
                if (!states.TryGetValue(StateKey(offset, prevEnd), out Block? state))
                {
                    stack.Push(new Frame(true, offset, prevEnd));
                    return false;
                }
                winner[index] = new Block(_optimalBits[index], index, offset,
                    LiteralRun(state, litAt));
                break;
            }
            case New:
            {
                Block? previous = winner[index - _winAux[index]];
                if (previous is null)
                {
                    stack.Push(new Frame(false, 0, index - _winAux[index]));
                    return false;
                }
                winner[index] = new Block(_optimalBits[index], index, offset, previous);
                break;
            }
            default:
                throw new InvalidOperationException($"Position {index} has no winner");
        }
        return true;
    }

    private bool ResolveState(Frame frame, Dictionary<long, Block> states,
                              Block?[] winner, Stack<Frame> stack)
    {
        int offset = frame.Offset;
        int end = frame.Index;
        if (!frame.Scanned)
        {
            frame.Scanned = true;
            int start = end;
            while (Matches(start - 1, offset))
            {
                start--;
            }
            frame.RunStart = start;
            frame.PrevEnd = PreviousStateEnd(offset, start - 1);
            int run = end - start + 1;
            if (run >= 2)
            {
                int bestCore = int.MaxValue;
                for (int length = 2; length <= run; length++)
                {
                    int core = _optimalBits[end - length] + EliasGammaBits(length - 1);
                    if (core <= bestCore)
                    {
                        // Ties go to the longer split, as the reference ladder.
                        bestCore = core;
                        frame.NewLength = length;
                    }
                }
                frame.NewBits = bestCore + 1 + (offset > 128 ? 16 : 8);
            }
        }

        if (frame.PrevEnd != None)
        {
            // The rep candidate exists.
            if (!states.TryGetValue(StateKey(offset, frame.PrevEnd), out Block? previousState))
            {
                stack.Push(new Frame(true, offset, frame.PrevEnd));
                return false;
            }
            Block literal = LiteralRun(previousState, frame.RunStart - 1);
            int repBits = literal.Bits + 1 + EliasGammaBits(end - frame.RunStart + 1);
            if (frame.NewLength == 0 || repBits <= frame.NewBits)
            {
                states[StateKey(offset, end)] = new Block(repBits, end, offset, literal);
                return true;
            }
        }
        Block? previous = winner[end - frame.NewLength];
        if (previous is null)
        {
            stack.Push(new Frame(false, 0, end - frame.NewLength));
            return false;
        }
        states[StateKey(offset, end)] = new Block(frame.NewBits, end, offset, previous);
        return true;
    }

    /// <summary>The literal run from just after <paramref name="state"/>
    /// through <paramref name="litEnd"/>.</summary>
    private static Block LiteralRun(Block state, int litEnd)
    {
        int length = litEnd - state.Index;
        int bits = state.Bits + 1 + EliasGammaBits(length) + length * 8;
        return new Block(bits, litEnd, 0, state);
    }

    /// <summary>
    /// Where this offset's state ended at or before <paramref name="from"/>,
    /// or None. That is the last match at the offset - but only once any state
    /// exists, which is from the first adjacent-pair match on; lone matches
    /// before that never created one. Offset one's fallback is the fake block
    /// just before the parse starts.
    /// </summary>
    private int PreviousStateEnd(int offset, int from)
    {
        int lastMatch = None;
        for (int index = from; index > _skip && index >= offset; index--)
        {
            if (_input[index] == _input[index - offset])
            {
                if (lastMatch == None)
                {
                    lastMatch = index;
                }
                if (offset == Optimizer.InitialOffset || Matches(index - 1, offset))
                {
                    return lastMatch;
                }
            }
        }
        return offset == Optimizer.InitialOffset ? _skip - 1 : None;
    }
}
