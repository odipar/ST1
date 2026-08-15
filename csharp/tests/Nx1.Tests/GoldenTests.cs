using Xunit;

namespace Nx1.Tests;

public sealed class GoldenTests
{
    private static Compressor.Result Compress(
        byte[] input,
        int skip,
        int offsetLimit,
        bool backwards) =>
        Compressor.Compress(
            Optimizer.Optimize(input, skip, offsetLimit),
            input,
            skip,
            backwards);

    private static void AssertGolden(
        string expectedHex,
        int expectedDelta,
        Compressor.Result actual)
    {
        Assert.Equal(Convert.FromHexString(expectedHex), actual.Output);
        Assert.Equal(expectedDelta, actual.Delta);
    }

    [Fact]
    public void Text()
    {
        AssertGolden(
            "f761627261636164f22a6920686f6375732070f4d0bdb8baaf40ffff",
            2,
            Compress(TestData.Text(), 0, global::Nx1.Nx1.MaxOffsetZx1, false));
    }

    [Fact]
    public void TextWithSkip()
    {
        AssertGolden(
            "dc636164f2a920686f6375732070f4a6d0f6b8eabdffff",
            2,
            Compress(TestData.Text(), 4, global::Nx1.Nx1.MaxOffsetZx1, false));
    }

    [Fact]
    public void TextBackwards()
    {
        byte[] input = TestData.Text();
        Array.Reverse(input);
        Compressor.Result result = Compress(
            input,
            0,
            global::Nx1.Nx1.MaxOffsetZx1 - 1,
            true);
        Array.Reverse(result.Output);

        AssertGolden(
            "0001d0ab466e2e686f0a706f6375732068ce0c6361646162726120a9",
            2,
            result);
    }

    [Fact]
    public void FarMatch()
    {
        AssertGolden(
            "ebac73d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9be"
            + "f76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4ef"
            + "3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01dcc"
            + "eb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a560"
            + "17e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b887b"
            + "b478afeabd75e8eafdffff",
            2,
            Compress(TestData.FarMatch(), 0, global::Nx1.Nx1.MaxOffsetZx1, false));
    }

    [Fact]
    public void FarMatchQuickMode()
    {
        AssertGolden(
            "ebac73d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9be"
            + "f76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4ef"
            + "3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01dcc"
            + "eb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a560"
            + "17e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b887b"
            + "b478afeabceba973d51abbd89cb8196f0efb6892f94d68fccc2c35f0b84609e5f12c55dd85aba8d5d9"
            + "bef76808f3b572e5900112b81927ba5bb5f67e1bda28b4049bf0e4aed78db15d7bf2fc0c34e9a99de4"
            + "ef3bc2b17c8137ad659878f9e93df1f658367aca286452474b9ef3765e24e9a88173724dddfb04b01d"
            + "cceb0c8aead641c58dad569581baeea87c10d40a47902028e61cfdc243d9d16008aabc9fb77cc723a5"
            + "6017e14f1ce8b1698341734a6823ce02043e016b544901214a2ddab82fec85c0b9fe0549c475be5b88"
            + "7bb4ffff",
            4,
            Compress(TestData.FarMatch(), 0, global::Nx1.Nx1.MaxOffsetZx7, false));
    }

    [Fact]
    public void WordSoup()
    {
        Compressor.Result result = Compress(
            TestData.WordSoup(),
            0,
            global::Nx1.Nx1.MaxOffsetZx1,
            false);

        Assert.Equal(777, result.Output.Length);
        Assert.Equal(2, result.Delta);
        Assert.Equal(TestData.WordSoup(), Decompressor.Decompress(result.Output));
    }
}
