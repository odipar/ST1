// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

namespace Nx1;

/// <summary>
/// <see cref="Optimizer"/>, restructured to not allocate: the same parse,
/// found the same way, producing byte-identical output.
/// </summary>
/// <remarks>
/// The original materialises every candidate as a <see cref="Block"/>, and
/// nearly all of them lose and become garbage - gigabytes of allocation per
/// packed asset. This version runs the identical DP forward on primitive
/// arrays, recording per position the winning cost and a three-int descriptor
/// of the winning candidate, then builds only the blocks the winning chain
/// actually contains by replaying each recorded decision backward from the
/// descriptors, the winning costs and the data itself. Candidates are
/// evaluated in the same order with the same strictly-better replacement rule,
/// so ties fall exactly as in the original; <see cref="Optimizer"/> stays in
/// the tree as the specification this class is checked against.
/// </remarks>
public static class FastOptimizer
{
    private const int None = int.MinValue;

    /// <summary>Finds the minimum-bit parse of <paramref name="input"/> - the
    /// same chain <see cref="Optimizer.Optimize"/> returns, byte for byte -
    /// reporting progress on stdout while it works.</summary>
    public static Block Optimize(byte[] input, int skip, int offsetLimit) =>
        Optimize(input, skip, offsetLimit, progress: true);

    /// <summary>As above; <paramref name="progress"/> false works silently,
    /// for callers that are not a person at a terminal.</summary>
    public static Block Optimize(byte[] input, int skip, int offsetLimit, bool progress)
    {
        Validate(input, skip, offsetLimit);
        var pass = new ForwardPass(input, skip, offsetLimit);
        pass.Run(progress);
        return new ChainRebuilder(input, skip, pass.OptimalBits,
            pass.WinKind, pass.WinOffset, pass.WinAux).Rebuild();
    }

    /// <summary>The winning cost per position, for the tests that hold other
    /// optimizers to this one: the optimum is unique, so any exact optimizer
    /// must produce this exact array.</summary>
    internal static int[] Costs(byte[] input, int skip, int offsetLimit)
    {
        var pass = new ForwardPass(input, skip, offsetLimit);
        pass.Run(progress: false);
        return pass.OptimalBits;
    }

    internal static void Validate(byte[] input, int skip, int offsetLimit)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.Length == 0)
        {
            throw new ArgumentException("Input must not be empty", nameof(input));
        }
        if (skip < 0 || skip >= input.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(skip));
        }
        if (offsetLimit < Optimizer.InitialOffset || offsetLimit > Nx1.MaxOffsetZx1)
        {
            throw new ArgumentOutOfRangeException(nameof(offsetLimit));
        }
    }

    private static int EliasGammaBits(int value) =>
        2 * (31 - System.Numerics.BitOperations.LeadingZeroCount((uint)value)) + 1;

    /// <summary>The DP of <see cref="Optimizer.Optimize"/>, candidate for
    /// candidate, on primitives.</summary>
    internal sealed class ForwardPass(byte[] input, int skip, int offsetLimit)
    {
        internal readonly int[] OptimalBits = new int[input.Length];
        internal readonly byte[] WinKind = new byte[input.Length];
        internal readonly int[] WinOffset = new int[input.Length];
        internal readonly int[] WinAux = new int[input.Length];

        internal void Run(bool progress)
        {
            int count = input.Length;
            int width = (int)Math.Clamp(count - 1L, Optimizer.InitialOffset, offsetLimit);
            var stateBits = new int[width + 1];
            var stateEnd = new int[width + 1];
            var litBits = new int[width + 1];
            var litEnd = new int[width + 1];
            var matchLength = new int[width + 1];
            Array.Fill(stateEnd, None);
            Array.Fill(litEnd, None);
            var bestLength = new int[Math.Max(count, 3)];
            bestLength[2] = 2;

            // The fake block every chain hangs from, ending just before the start.
            stateBits[Optimizer.InitialOffset] = -1;
            stateEnd[Optimizer.InitialOffset] = skip - 1;

            var meter = new ProgressMeter(
                ProgressMeter.TotalSteps(count, skip, offsetLimit), progress);

            for (int index = skip; index < count; index++)
            {
                int maxOffset = (int)Math.Clamp(index, Optimizer.InitialOffset, offsetLimit);
                int bestLengthSize = 2;
                byte value = input[index];
                int best = int.MaxValue;
                for (int offset = 1; offset <= maxOffset; offset++)
                {
                    if (index != skip && index >= offset && value == input[index - offset])
                    {
                        // Copy from last offset, after a literal run.
                        if (litEnd[offset] != None)
                        {
                            int bits = litBits[offset] + 1
                                + EliasGammaBits(index - litEnd[offset]);
                            stateBits[offset] = bits;
                            stateEnd[offset] = index;
                            if (bits < best)
                            {
                                best = bits;
                                WinKind[index] = ChainRebuilder.Rep;
                                WinOffset[index] = offset;
                                WinAux[index] = litEnd[offset];
                            }
                        }

                        // Copy from a new offset, at the best split length.
                        if (++matchLength[offset] > 1)
                        {
                            if (bestLengthSize < matchLength[offset])
                            {
                                int bits = OptimalBits[index - bestLength[bestLengthSize]]
                                    + EliasGammaBits(bestLength[bestLengthSize] - 1);
                                do
                                {
                                    bestLengthSize++;
                                    int shorterBits = OptimalBits[index - bestLengthSize]
                                        + EliasGammaBits(bestLengthSize - 1);
                                    if (shorterBits <= bits)
                                    {
                                        bestLength[bestLengthSize] = bestLengthSize;
                                        bits = shorterBits;
                                    }
                                    else
                                    {
                                        bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                    }
                                }
                                while (bestLengthSize < matchLength[offset]);
                            }
                            int length = bestLength[matchLength[offset]];
                            int newBits = OptimalBits[index - length] + 1
                                + (offset > 128 ? 16 : 8)
                                + EliasGammaBits(length - 1);
                            if (stateEnd[offset] != index || stateBits[offset] > newBits)
                            {
                                stateBits[offset] = newBits;
                                stateEnd[offset] = index;
                                if (newBits < best)
                                {
                                    best = newBits;
                                    WinKind[index] = ChainRebuilder.New;
                                    WinOffset[index] = offset;
                                    WinAux[index] = length;
                                }
                            }
                        }
                    }
                    else
                    {
                        // Literals, continuing from the offset's last match.
                        matchLength[offset] = 0;
                        if (stateEnd[offset] != None)
                        {
                            int length = index - stateEnd[offset];
                            int bits = stateBits[offset] + 1 + EliasGammaBits(length)
                                + length * 8;
                            litBits[offset] = bits;
                            litEnd[offset] = index;
                            if (bits < best)
                            {
                                best = bits;
                                WinKind[index] = ChainRebuilder.Literals;
                                WinOffset[index] = offset;
                                WinAux[index] = stateEnd[offset];
                            }
                        }
                    }
                }
                OptimalBits[index] = best;
                meter.Advance(maxOffset);
            }
            meter.Finish();
        }
    }
}
