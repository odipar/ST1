using Xunit;

namespace Nx1.Tests;

public sealed class RoundTripTests
{
    private static byte[] Compress(byte[] input) =>
        Compressor.Compress(
            Optimizer.Optimize(input, 0, global::Nx1.Nx1.MaxOffsetZx1),
            input,
            0,
            false).Output;

    [Fact]
    public void RoundTripsVariousInputs()
    {
        var random = new byte[500];
        new JavaRandom(7).NextBytes(random);

        var allSame = new byte[1_000];
        Array.Fill(allSame, (byte)'A');

        var alternating = new byte[64];
        for (int index = 0; index < alternating.Length; index++)
        {
            alternating[index] = (byte)(index % 2);
        }

        byte[][] inputs =
        [
            [42],
            [1, 1],
            [1, 2],
            random,
            allSame,
            alternating,
            TestData.Text(),
            TestData.FarMatch(),
            TestData.WordSoup(),
        ];

        foreach (byte[] input in inputs)
        {
            Assert.Equal(input, Decompressor.Decompress(Compress(input)));
        }
    }

    [Fact]
    public void QuickModeRoundTrips()
    {
        byte[] input = TestData.FarMatch();
        byte[] output = Compressor.Compress(
            Optimizer.Optimize(input, 0, global::Nx1.Nx1.MaxOffsetZx7),
            input,
            0,
            false).Output;

        Assert.Equal(input, Decompressor.Decompress(output));
    }

    [Fact]
    public void RejectsTruncatedInput()
    {
        byte[] compressed = Compress(TestData.Text());
        byte[] truncated = compressed[..^2];

        Assert.Throws<InvalidDataException>(() => Decompressor.Decompress(truncated));
    }

    [Fact]
    public void RejectsTrailingGarbage()
    {
        byte[] compressed = Compress(TestData.Text());
        byte[] tooLong = new byte[compressed.Length + 1];
        compressed.CopyTo(tooLong, 0);

        Assert.Throws<InvalidDataException>(() => Decompressor.Decompress(tooLong));
    }

    [Fact]
    public void RejectsInvalidBackReference()
    {
        byte[] malformed = [0b0100_0000, (byte)'A', 252, 0];

        Assert.Throws<InvalidDataException>(() => Decompressor.Decompress(malformed));
    }
}
