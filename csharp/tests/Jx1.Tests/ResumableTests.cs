using Xunit;

namespace Jx1.Tests;

public sealed class ResumableTests
{
    private static byte[] Compress(byte[] input, int offsetLimit) =>
        Compressor.Compress(
            Optimizer.Optimize(input, 0, offsetLimit),
            input,
            0,
            false).Output;

    private sealed class Collector : Decompressor
    {
        internal Collector(byte[] input, byte[] buffer, int chunkSize)
            : base(input, buffer, chunkSize)
        {
        }

        internal MemoryStream Output { get; } = new();

        protected override void Flip(byte[] buffer, int length) =>
            Output.Write(buffer, 0, length);
    }

    [Fact]
    public void ResumeCallCountMatchesChunkSize()
    {
        byte[] input = TestData.Text();
        byte[] compressed = Compress(input, 511);
        foreach (int chunkSize in new[] { 1, 7, 100, 359, 360, 361, 10_000 })
        {
            var collector = new Collector(compressed, new byte[512], chunkSize);
            int calls = 1;
            while (collector.Resume())
            {
                calls++;
            }

            Assert.Equal((input.Length + chunkSize - 1) / chunkSize, calls);
            Assert.Equal(input, collector.Output.ToArray());
            Assert.False(collector.Resume());
        }
    }

    [Fact]
    public void EachResumeEmitsAtMostOneChunk()
    {
        var input = new byte[1_000];
        Array.Fill(input, (byte)'A');
        byte[] compressed = Compress(input, 1);
        var collector = new Collector(compressed, new byte[1], 64);
        long previousSize = 0;

        while (collector.Resume())
        {
            Assert.Equal(64, collector.Output.Length - previousSize);
            previousSize = collector.Output.Length;
        }

        Assert.Equal(1_000, collector.Output.Length);
        Assert.Equal(input, collector.Output.ToArray());
    }

    [Fact]
    public void ResumingInterleavesWithRingFlips()
    {
        byte[] input = TestData.WordSoup();
        byte[] compressed = Compress(input, 100);
        var collector = new Collector(compressed, new byte[100], 37);

        while (collector.Resume())
        {
        }

        Assert.Equal(input, collector.Output.ToArray());
    }

    [Fact]
    public void RejectsOverflowedGammaLengthImmediately()
    {
        byte[] malformed = [0x2a, 0x41, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x00];
        var collector = new Collector(malformed, new byte[512], 100);

        Assert.Throws<InvalidDataException>(collector.Decompress);
        Assert.Equal(0, collector.Output.Length);
    }

    [Fact]
    public void ResumeAfterCompletedDecompressReturnsFalse()
    {
        byte[] input = TestData.Text();
        var collector = new Collector(Compress(input, 511), new byte[512], 100);

        collector.Decompress();

        Assert.Equal(input, collector.Output.ToArray());
        Assert.False(collector.Resume());
    }
}
