// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

namespace Nx1;

/// <summary>
/// The event-driven optimizer: the same costs as <see cref="FastOptimizer"/>,
/// without visiting every (position, offset) pair.
/// </summary>
/// <remarks>
/// <para>The DP's per-step work is redundant in a specific way: between the
/// start and end of a match run, and along a literal stretch, every
/// candidate's cost is a closed form of the position. Only run boundaries
/// change anything, and on repetitive data there are orders of magnitude fewer
/// of those than DP steps. Candidates live in min-trees keyed by state end and
/// run start, so one range-min per gamma class of the age answers a whole
/// window and nothing moves as the position advances: the query ranges do. Run
/// starts and ends are enumerated exactly by occurrence chains keyed
/// (value, predecessor) and (value, successor).</para>
/// <para>This reproduces <see cref="FastOptimizer"/>'s cost array element for
/// element - the equivalence test asserts exactly that - but where candidates
/// tie, the recorded winner may differ, so the compressed bytes can differ
/// while the compressed size cannot beyond one byte of control-bit rounding.
/// That is why only quick mode uses it: nx1's default output stays
/// byte-identical to the reference. The trade is per-event overhead for
/// per-step savings, so <see cref="Optimize(byte[], int, int, bool)"/> counts
/// the events first and falls back to <see cref="FastOptimizer"/> when the
/// data is run-churny. One special case covers <c>skip</c>: the DP defines
/// match(skip) as false regardless of the data, so at position skip+1 every
/// in-window occurrence starts a run, whatever its predecessor.</para>
/// </remarks>
public sealed class EventOptimizer
{
    private const int None = int.MinValue;

    /// <summary>Fall back to the plain DP when events exceed positions this
    /// many times.</summary>
    private const int Churn = 8;

    private readonly byte[] _input;
    private readonly int _skip;
    private readonly int _offsetLimit;

    private readonly int[] _optimalBits;
    private readonly byte[] _winKind;
    private readonly int[] _winOffset;
    private readonly int[] _winAux;

    // Per offset: the state (best chain ending in its last match), the current
    // run's start and frozen literal key, None/-1 when absent.
    private readonly int[] _stateBits;
    private readonly int[] _stateEnd;
    private readonly int[] _runStartOf;
    private readonly int[] _litKeyOf;

    // Channel structures: min-trees with per-slot sets where entries retire.
    private readonly SlotTree _literalTree;     // by state end e (slot e+1)
    private readonly SlotTree _repTree;         // by run start s
    private readonly MinTree _costTree;         // recorded costs, argmin position
    private readonly PriorityQueue<long, long> _byteRuns = new();
    private readonly PriorityQueue<long, long> _wordRuns = new();

    // Occurrence chains: positions by (value, predecessor) and (value,
    // successor), newest first, for exact run start and end enumeration. The
    // predecessor key -1 means "no predecessor": position zero.
    private readonly Dictionary<int, Dictionary<int, int>> _byPred = new();
    private readonly Dictionary<int, Dictionary<int, int>> _bySucc = new();
    private readonly int[] _predNext;
    private readonly int[] _succNext;

    private EventOptimizer(byte[] input, int skip, int offsetLimit)
    {
        _input = input;
        _skip = skip;
        _offsetLimit = offsetLimit;
        int count = input.Length;
        _optimalBits = new int[count];
        _winKind = new byte[count];
        _winOffset = new int[count];
        _winAux = new int[count];
        int width = (int)Math.Clamp(count - 1L, 1, offsetLimit);
        _stateBits = new int[width + 1];
        _stateEnd = new int[width + 1];
        _runStartOf = new int[width + 1];
        _litKeyOf = new int[width + 1];
        Array.Fill(_stateEnd, None);
        Array.Fill(_runStartOf, -1);
        _literalTree = new SlotTree(count + 1);
        _repTree = new SlotTree(count + 1);
        _costTree = new MinTree(count);
        _predNext = new int[count];
        _succNext = new int[count];
    }

    /// <summary>
    /// Finds a minimum-bit parse of <paramref name="input"/> - the same cost
    /// as <see cref="FastOptimizer"/>, not necessarily the same chain. Falls
    /// back to the fast optimizer when a cheap event count says the data is
    /// run-churny and the DP would be faster.
    /// </summary>
    public static Block Optimize(byte[] input, int skip, int offsetLimit, bool progress)
    {
        FastOptimizer.Validate(input, skip, offsetLimit);
        var optimizer = new EventOptimizer(input, skip, offsetLimit);
        if (optimizer.CountEvents() > (long)Churn * input.Length)
        {
            return FastOptimizer.Optimize(input, skip, offsetLimit, progress);
        }
        optimizer.Run(progress);
        return new ChainRebuilder(input, skip, optimizer._optimalBits,
            optimizer._winKind, optimizer._winOffset, optimizer._winAux).Rebuild();
    }

    /// <summary>As above, reporting progress on stdout.</summary>
    public static Block Optimize(byte[] input, int skip, int offsetLimit) =>
        Optimize(input, skip, offsetLimit, progress: true);

    /// <summary>The winning cost per position, for the equivalence tests.</summary>
    internal static int[] Costs(byte[] input, int skip, int offsetLimit)
    {
        var optimizer = new EventOptimizer(input, skip, offsetLimit);
        optimizer.Run(progress: false);
        return optimizer._optimalBits;
    }

    private static int EliasGammaBits(int value) =>
        2 * (31 - System.Numerics.BitOperations.LeadingZeroCount((uint)value)) + 1;

    // ------------------------------------------------------------------ events

    /// <summary>
    /// Run starts at <paramref name="j"/>: offsets whose byte matches at j but
    /// not at j-1. Those are the in-window occurrences of input[j] whose
    /// predecessor differs from input[j-1] - or that have none at all - so the
    /// chains keyed (value, predecessor) enumerate exactly them, newest first,
    /// stopping at the window's edge.
    /// </summary>
    private void ForEachRunStart(int j, Action<int> onEvent)
    {
        if (!_byPred.TryGetValue(_input[j], out var groups))
        {
            return;
        }
        int predecessor = _input[j - 1];
        long lowest = Math.Max(0, (long)j - _offsetLimit);
        foreach (var group in groups)
        {
            if (group.Key == predecessor)
            {
                continue;                       // those continue a run
            }
            for (int p = group.Value; p >= lowest; p = _predNext[p])
            {
                onEvent(j - p);
            }
        }
    }

    /// <summary>Run ends at e = j-1: matches at j-1 whose successor differs at j.</summary>
    private void ForEachRunEnd(int j, Action<int> onEvent)
    {
        if (!_bySucc.TryGetValue(_input[j - 1], out var groups))
        {
            return;
        }
        int successor = _input[j];
        long lowest = Math.Max(0, (long)(j - 1) - _offsetLimit);
        foreach (var group in groups)
        {
            if (group.Key == successor)
            {
                continue;                       // those keep matching
            }
            for (int p = group.Value; p >= lowest; p = _succNext[p])
            {
                onEvent(j - 1 - p);
            }
        }
    }

    /// <summary>Chains position j for future starts, and j-1 for future ends.</summary>
    private void Chain(int j)
    {
        int predecessor = j > 0 ? _input[j - 1] : -1;
        var predGroups = GetOrAdd(_byPred, _input[j]);
        _predNext[j] = predGroups.TryGetValue(predecessor, out int old) ? old : int.MinValue;
        predGroups[predecessor] = j;
        if (j > 0)
        {
            var succGroups = GetOrAdd(_bySucc, _input[j - 1]);
            _succNext[j - 1] = succGroups.TryGetValue(_input[j], out old) ? old : int.MinValue;
            succGroups[_input[j]] = j - 1;
        }
    }

    private static Dictionary<int, int> GetOrAdd(
        Dictionary<int, Dictionary<int, int>> chains, int value)
    {
        if (!chains.TryGetValue(value, out var groups))
        {
            groups = new Dictionary<int, int>();
            chains[value] = groups;
        }
        return groups;
    }

    /// <summary>
    /// Every in-window occurrence of input[j], regardless of predecessor: the
    /// run starts at position skip+1, where match(skip) is false by rule and
    /// the predecessor-based chains would call a data-match a continuation.
    /// </summary>
    private void ForEachMatchSource(int j, Action<int> onEvent)
    {
        if (!_byPred.TryGetValue(_input[j], out var groups))
        {
            return;
        }
        long lowest = Math.Max(0, (long)j - _offsetLimit);
        foreach (var group in groups)
        {
            for (int p = group.Value; p >= lowest; p = _predNext[p])
            {
                onEvent(j - p);
            }
        }
    }

    /// <summary>One cheap pass counting run events, to decide engine or plain DP.</summary>
    private long CountEvents()
    {
        long events = 0;
        for (int p = 0; p < _skip; p++)
        {
            Chain(p);
        }
        for (int j = _skip; j < _input.Length; j++)
        {
            if (j == _skip + 1)
            {
                ForEachMatchSource(j, _ => events++);
            }
            else if (j > _skip + 1)
            {
                ForEachRunEnd(j, _ => events++);
                ForEachRunStart(j, _ => events++);
            }
            Chain(j);
        }
        // The pass consumed the chains; rebuild them empty for the real run.
        _byPred.Clear();
        _bySucc.Clear();
        return events;
    }

    // ---------------------------------------------------------------- the loop

    private void Run(bool progress)
    {
        int count = _input.Length;
        var meter = new ProgressMeter(
            ProgressMeter.TotalSteps(count, _skip, _offsetLimit), progress);

        // The fake state every chain hangs from: offset one, just before the
        // parse starts, as the reference DP seeds it.
        _stateBits[1] = -1;
        _stateEnd[1] = _skip - 1;
        _literalTree.Insert(_skip, Encode(-1 - (_skip - 1) * 8, 1));

        for (int p = 0; p < _skip; p++)
        {
            Chain(p);                       // sources matches may reach into
        }
        for (int j = _skip; j < count; j++)
        {
            int at = j;
            if (j == _skip + 1)
            {
                // match(skip) is false by rule, so no run covers skip: every
                // in-window occurrence here starts one, whatever its
                // predecessor, and there is nothing yet that could end.
                ForEachMatchSource(j, offset => StartRun(offset, at));
            }
            else if (j > _skip + 1)
            {
                ForEachRunEnd(j, offset => EndRun(offset, at - 1));
                ForEachRunStart(j, offset => StartRun(offset, at));
            }

            int best = int.MaxValue;
            byte kind = 0;
            int bestOffset = 0;
            int aux = 0;

            // Literal channel: one range-min per gamma class of the age j-e.
            for (int t = 0; (1L << t) <= j + 1 - _skip; t++)
            {
                int lowest = j - (1 << (t + 1)) + 1;        // e range for this class
                int highest = j - (1 << t);
                long enc = _literalTree.Min(Math.Max(0, lowest + 1), highest + 1);
                if (enc == long.MaxValue)
                {
                    continue;
                }
                int candidate = Key(enc) + j * 8 + 1 + (2 * t + 1);
                if (candidate < best)
                {
                    best = candidate;
                    kind = ChainRebuilder.Literals;
                    bestOffset = OffsetOf(enc);
                    aux = _stateEnd[bestOffset];
                }
            }

            // Rep channel: the same, keyed by run start.
            for (int t = 0; (1L << t) <= j - _skip; t++)
            {
                int lowest = j - (1 << (t + 1)) + 2;        // s range for this class
                int highest = j - (1 << t) + 1;
                if (highest < 1)
                {
                    continue;
                }
                long enc = _repTree.Min(Math.Max(1, lowest), highest);
                if (enc == long.MaxValue)
                {
                    continue;
                }
                int candidate = Key(enc) + 1 + (2 * t + 1);
                if (candidate < best)
                {
                    best = candidate;
                    kind = ChainRebuilder.Rep;
                    bestOffset = OffsetOf(enc);
                    aux = _runStartOf[bestOffset] - 1;
                }
            }

            // New-offset channel: range-mins over recorded costs, cut to the
            // longest active run of each offset class.
            long byteTop = Top(_byteRuns);
            long wordTop = Top(_wordRuns);
            int maxByte = byteTop == long.MaxValue ? 0 : j - (int)(byteTop >>> 16) + 1;
            int maxWord = wordTop == long.MaxValue ? 0 : j - (int)(wordTop >>> 16) + 1;
            for (int t = 0; ; t++)
            {
                int lenLo = (1 << t) + 1;
                if (lenLo > maxWord)
                {
                    break;
                }
                int lenHi = 1 << (t + 1);
                int gammaBits = 2 * t + 1;
                for (int half = 0; half < 2; half++)
                {
                    int reach = half == 0 ? Math.Min(maxByte, lenHi)
                                          : Math.Min(maxWord, lenHi);
                    if (reach < lenLo)
                    {
                        continue;
                    }
                    long enc = _costTree.Min(j - reach, j - lenLo);
                    if (enc == long.MaxValue)
                    {
                        continue;
                    }
                    int candidate = (int)(enc >>> 22) + gammaBits + 1
                        + (half == 0 ? 8 : 16);
                    if (candidate < best)
                    {
                        best = candidate;
                        kind = ChainRebuilder.New;
                        long runTop = half == 0 ? byteTop : wordTop;
                        bestOffset = (int)(runTop & 0xFFFF);
                        aux = j - (int)(enc & 0x3FFFFF);    // the split length
                    }
                }
            }

            _optimalBits[j] = best;
            _winKind[j] = kind;
            _winOffset[j] = bestOffset;
            _winAux[j] = aux;
            _costTree.Set(j, ((long)best << 22) | (uint)j);

            Chain(j);
            meter.Advance((int)Math.Clamp(j, 1, _offsetLimit));
        }
        meter.Finish();
    }

    private void StartRun(int offset, int start)
    {
        _runStartOf[offset] = start;
        if (_stateEnd[offset] != None)
        {
            int length = (start - 1) - _stateEnd[offset];
            int litKey = _stateBits[offset] + 1 + EliasGammaBits(length) + length * 8;
            _litKeyOf[offset] = litKey;
            _repTree.Insert(start, Encode(litKey, offset));
        }
        else
        {
            _litKeyOf[offset] = None;
        }
        long entry = ((long)start << 16) | (uint)offset;
        _wordRuns.Enqueue(entry, entry);
        if (offset <= 128)
        {
            _byteRuns.Enqueue(entry, entry);
        }
    }

    private void EndRun(int offset, int end)
    {
        int start = _runStartOf[offset];
        int run = end - start + 1;
        int state = int.MaxValue;
        if (_litKeyOf[offset] != None)
        {
            _repTree.Remove(start, Encode(_litKeyOf[offset], offset));
            state = _litKeyOf[offset] + 1 + EliasGammaBits(run);
        }
        if (run >= 2)
        {
            int core = BestSplit(end, run);
            if (core != int.MaxValue)
            {
                state = Math.Min(state, core + 1 + (offset > 128 ? 16 : 8));
            }
        }
        if (state != int.MaxValue)
        {
            if (_stateEnd[offset] != None)
            {
                // The reference DP overwrites an offset's state at its next
                // match run regardless of cost; replicate that exactly.
                _literalTree.Remove(_stateEnd[offset] + 1,
                    Encode(_stateBits[offset] - _stateEnd[offset] * 8, offset));
            }
            _literalTree.Insert(end + 1, Encode(state - end * 8, offset));
            _stateBits[offset] = state;
            _stateEnd[offset] = end;
        }
        _runStartOf[offset] = -1;
    }

    /// <summary>Min over lengths 2..reach of cost[end-length] + gamma(length-1).</summary>
    private int BestSplit(int end, int reach)
    {
        int best = int.MaxValue;
        for (int t = 0; ; t++)
        {
            int lenLo = (1 << t) + 1;
            if (lenLo > reach)
            {
                break;
            }
            int lenHi = Math.Min(reach, 1 << (t + 1));
            long enc = _costTree.Min(end - lenHi, end - lenLo);
            if (enc != long.MaxValue)
            {
                best = Math.Min(best, (int)(enc >>> 22) + 2 * t + 1);
            }
        }
        return best;
    }

    private static long Encode(int keyValue, int offset) =>
        ((long)keyValue << 16) | (uint)offset;

    private static int Key(long encoded) => (int)(encoded >> 16);

    private static int OffsetOf(long encoded) => (int)(encoded & 0xFFFF);

    /// <summary>The smallest valid (start, offset) entry; stale runs pop lazily.</summary>
    private long Top(PriorityQueue<long, long> runs)
    {
        while (runs.TryPeek(out long entry, out _))
        {
            if (_runStartOf[(int)(entry & 0xFFFF)] == (int)(entry >>> 16))
            {
                return entry;
            }
            runs.Dequeue();
        }
        return long.MaxValue;
    }

    // ------------------------------------------------------------- structures

    /// <summary>An iterative min segment tree over longs.</summary>
    private class MinTree
    {
        private protected readonly long[] Nodes;
        private protected readonly int Size;

        internal MinTree(int width)
        {
            Size = (int)System.Numerics.BitOperations.RoundUpToPowerOf2(
                (uint)Math.Max(2, width));
            Nodes = new long[2 * Size];
            Array.Fill(Nodes, long.MaxValue);
        }

        internal void Set(int at, long value)
        {
            int node = at + Size;
            Nodes[node] = value;
            for (node >>= 1; node > 0; node >>= 1)
            {
                Nodes[node] = Math.Min(Nodes[2 * node], Nodes[2 * node + 1]);
            }
        }

        /// <summary>Minimum over the inclusive range, MaxValue when empty.</summary>
        internal long Min(int from, int to)
        {
            if (from < 0)
            {
                from = 0;
            }
            if (to >= Size)
            {
                to = Size - 1;
            }
            long best = long.MaxValue;
            int lo = from + Size;
            int hi = to + Size + 1;
            while (lo < hi)
            {
                if ((lo & 1) != 0)
                {
                    best = Math.Min(best, Nodes[lo++]);
                }
                if ((hi & 1) != 0)
                {
                    best = Math.Min(best, Nodes[--hi]);
                }
                lo >>= 1;
                hi >>= 1;
            }
            return best;
        }
    }

    /// <summary>A min tree whose slots hold sets, so entries can retire exactly.</summary>
    private sealed class SlotTree(int width) : MinTree(width)
    {
        private readonly Dictionary<int, SortedSet<long>> _slots = new();

        internal void Insert(int slot, long entry)
        {
            if (!_slots.TryGetValue(slot, out var set))
            {
                set = new SortedSet<long>();
                _slots[slot] = set;
            }
            set.Add(entry);
            Set(slot, set.Min);
        }

        internal void Remove(int slot, long entry)
        {
            if (_slots.TryGetValue(slot, out var set))
            {
                set.Remove(entry);
                Set(slot, set.Count == 0 ? long.MaxValue : set.Min);
            }
        }
    }
}
