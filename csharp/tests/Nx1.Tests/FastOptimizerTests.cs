// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

using Xunit;

namespace Nx1.Tests;

/// <summary>
/// <see cref="FastOptimizer"/> against <see cref="Optimizer"/>: the fast one
/// exists to find the same parse, so the compressed output must match byte for
/// byte on every input shape, window and skip.
/// </summary>
public sealed class FastOptimizerTests
{
    internal static byte[][] Inputs()
    {
        var random = new byte[4_096];
        new JavaRandom(7).NextBytes(random);
        var sparse = new byte[4_096];
        var r = new JavaRandom(11);
        for (int index = 0; index < sparse.Length; index++)
        {
            sparse[index] = (byte)(r.NextInt(4) * 17 + index % 3);
        }
        var allSame = new byte[3_000];
        Array.Fill(allSame, (byte)'A');
        var period = new byte[4_096];
        for (int index = 0; index < period.Length; index++)
        {
            period[index] = (byte)(index % 3);
        }
        var lone = new byte[2_048];
        r = new JavaRandom(3);
        for (int index = 0; index < lone.Length; index++)
        {
            lone[index] = (byte)r.NextInt(256);
        }
        Array.Copy(lone, 0, lone, 1_500, 300);
        byte[] text = System.Text.Encoding.ASCII.GetBytes(
            string.Concat(Enumerable.Repeat("abracadabra hocus pocus ", 40)));
        return [[42], [1, 2, 3], [7, 7], random, sparse, allSame, period, lone, text];
    }

    [Fact]
    public void FindsTheExactSameParse()
    {
        foreach (byte[] input in Inputs())
        {
            foreach (int window in (int[])[16, 128, 1_024, global::Nx1.Nx1.MaxOffsetZx1])
            {
                foreach (int skip in (int[])[0, 1, 5])
                {
                    if (skip >= input.Length)
                    {
                        continue;
                    }
                    byte[] reference = Compressor.Compress(
                        Optimizer.Optimize(input, skip, window),
                        input, skip, false).Output;
                    byte[] fast = Compressor.Compress(
                        FastOptimizer.Optimize(input, skip, window, progress: false),
                        input, skip, false).Output;
                    Assert.Equal(reference, fast);
                }
            }
        }
    }
}
