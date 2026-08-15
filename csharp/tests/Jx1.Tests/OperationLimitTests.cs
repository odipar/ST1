using Xunit;

namespace Jx1.Tests;

public sealed class OperationLimitTests
{
    [Fact]
    public void RejectsOffsetsOutsideTheFormatRange()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            Optimizer.Optimize([42], 0, global::Jx1.Jx1.MaxOffsetZx1 + 1));
    }

    [Fact]
    public void SplitsLongMatchesAtTheRequestedLimit()
    {
        var input = new byte[5_000];
        Array.Fill(input, (byte)'A');

        Compressor.Result result = Compressor.Compress(
            Optimizer.Optimize(input, 0, 1),
            input,
            0,
            false,
            1_000);

        Assert.True(result.LongestOp <= 1_000);
        Assert.Equal(input, Decompressor.Decompress(result.Output));
    }

    [Fact]
    public void ReportsAnUnsplittableLiteralRun()
    {
        var input = new byte[300];
        for (int index = 0; index < input.Length; index++)
        {
            input[index] = (byte)(index % 251);
        }

        Compressor.Result result = Compressor.Compress(
            Optimizer.Optimize(input, 0, 1),
            input,
            0,
            false,
            100);

        Assert.Equal(input.Length, result.LongestOp);
        Assert.Equal(input, Decompressor.Decompress(result.Output));
    }
}
