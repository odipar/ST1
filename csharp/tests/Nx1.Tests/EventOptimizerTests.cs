// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

using Xunit;

namespace Nx1.Tests;

/// <summary>
/// <see cref="EventOptimizer"/> against <see cref="FastOptimizer"/>: the
/// optimum is unique, so the engine's cost array must equal the DP's element
/// for element - the strongest check an optimizer that breaks ties differently
/// can be held to. Its chains must decompress back to the input, and compress
/// to within the one byte a different split of control bits against whole
/// bytes can round differently.
/// </summary>
public sealed class EventOptimizerTests
{
    [Fact]
    public void ComputesTheExactSameCosts()
    {
        foreach (byte[] input in FastOptimizerTests.Inputs())
        {
            foreach (int window in (int[])[16, 128, 1_024, global::Nx1.Nx1.MaxOffsetZx1])
            {
                foreach (int skip in (int[])[0, 1, 5])
                {
                    if (skip >= input.Length)
                    {
                        continue;
                    }
                    int[] reference = FastOptimizer.Costs(input, skip, window);
                    int[] engine = EventOptimizer.Costs(input, skip, window);
                    Assert.Equal(reference.Skip(skip), engine.Skip(skip));
                }
            }
        }
    }

    [Fact]
    public void ItsChainsRoundTripAtTheSameSize()
    {
        foreach (byte[] input in FastOptimizerTests.Inputs())
        {
            foreach (int window in (int[])[128, global::Nx1.Nx1.MaxOffsetZx1])
            {
                byte[] packed = Compressor.Compress(
                    EventOptimizer.Optimize(input, 0, window, progress: false),
                    input, 0, false).Output;
                Assert.Equal(input, Decompressor.Decompress(packed));
                byte[] reference = Compressor.Compress(
                    FastOptimizer.Optimize(input, 0, window, progress: false),
                    input, 0, false).Output;
                Assert.InRange(packed.Length, reference.Length - 1, reference.Length + 1);
            }
        }
    }
}
