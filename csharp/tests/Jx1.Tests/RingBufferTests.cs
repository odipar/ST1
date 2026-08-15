using Xunit;

namespace Jx1.Tests;

public sealed class RingBufferTests
{
    private static byte[] Compress(byte[] input, int offsetLimit) =>
        Compressor.Compress(
            Optimizer.Optimize(input, 0, offsetLimit),
            input,
            0,
            false).Output;

    private sealed class Collector : Decompressor
    {
        private readonly Action<byte[], int> flip;

        internal Collector(byte[] input, byte[] buffer, Action<byte[], int> flip)
            : base(input, buffer)
        {
            this.flip = flip;
        }

        protected override void Flip(byte[] buffer, int length) => flip(buffer, length);
    }

    [Fact]
    public void RoundTripsThroughSmallRingBuffers()
    {
        foreach (byte[] input in new[] { TestData.Text(), TestData.WordSoup() })
        {
            byte[] compressed = Compress(input, 511);
            foreach (int bufferSize in new[] { 511, 512, 600, 65_536 })
            {
                Assert.Equal(input, Decompressor.Decompress(compressed, new byte[bufferSize]));
            }
        }
    }

    [Fact]
    public void FlipsDeliverFullBuffersThenTheRemainder()
    {
        byte[] input = TestData.Text();
        byte[] compressed = Compress(input, 100);
        var flips = new List<int>();
        using var output = new MemoryStream();
        var decompressor = new Collector(compressed, new byte[100], (buffer, length) =>
        {
            flips.Add(length);
            output.Write(buffer, 0, length);
        });

        decompressor.Decompress();

        Assert.Equal(input, output.ToArray());
        Assert.Equal(input.Length / 100 + 1, flips.Count);
        foreach (int length in flips[..^1])
        {
            Assert.Equal(100, length);
        }
        Assert.Equal(input.Length % 100, flips[^1]);
    }

    [Fact]
    public void SupportsOffsetsUpToExactlyTheBufferSize()
    {
        var period = new byte[300];
        new JavaRandom(9).NextBytes(period);
        var input = new byte[1_500];
        for (int index = 0; index < input.Length; index++)
        {
            input[index] = period[index % period.Length];
        }

        byte[] compressed = Compress(input, 300);

        Assert.Equal(input, Decompressor.Decompress(compressed, new byte[300]));
        Assert.Throws<InvalidDataException>(() =>
            Decompressor.Decompress(compressed, new byte[299]));
    }

    [Fact]
    public void RejectsBackreferenceBeyondBufferSize()
    {
        byte[] compressed = Compress(TestData.FarMatch(), global::Jx1.Jx1.MaxOffsetZx1);

        InvalidDataException exception = Assert.Throws<InvalidDataException>(() =>
            Decompressor.Decompress(compressed, new byte[512]));

        Assert.StartsWith("Backreference beyond ring buffer", exception.Message);
    }

    [Fact]
    public void RleCopiesWrapAcrossTheBufferBoundary()
    {
        var input = new byte[1_000];
        Array.Fill(input, (byte)'A');
        byte[] compressed = Compress(input, 64);

        Assert.Equal(input, Decompressor.Decompress(compressed, new byte[64]));
    }

    [Fact]
    public void DecompressorInstancesAreReusable()
    {
        byte[] input = TestData.Text();
        byte[] compressed = Compress(input, 511);
        using var output = new MemoryStream();
        var decompressor = new Collector(
            compressed,
            new byte[512],
            (buffer, length) => output.Write(buffer, 0, length));

        decompressor.Decompress();
        decompressor.Decompress();

        byte[] actual = output.ToArray();
        Assert.Equal(2 * input.Length, actual.Length);
        Assert.Equal(input, actual[input.Length..]);
    }

    [Fact]
    public void RejectsEmptyBuffer()
    {
        byte[] compressed = Compress(TestData.Text(), 511);

        Assert.Throws<ArgumentException>(() =>
            Decompressor.Decompress(compressed, []));
    }
}
