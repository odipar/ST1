using Xunit;

using CompressorCli = global::Jx1.Jx1;
using DecompressorCli = global::Jx1.Djx1;

namespace Jx1.Tests;

public sealed class CliTests
{
    [Fact]
    public void CompressorAndDecompressorRoundTripWithExplicitPaths()
    {
        using var files = new TemporaryDirectory();
        string inputPath = files.PathFor("input.bin");
        string compressedPath = files.PathFor("output.zx1");
        string outputPath = files.PathFor("output.bin");
        byte[] input = TestData.Text();
        File.WriteAllBytes(inputPath, input);

        Assert.Equal(0, CompressorCli.Run(["-f", inputPath, compressedPath]));
        Assert.Equal(
            Convert.FromHexString("f761627261636164f22a6920686f6375732070f4d0bdb8baaf40ffff"),
            File.ReadAllBytes(compressedPath));
        Assert.Equal(0, DecompressorCli.Run(["-f", compressedPath, outputPath]));
        Assert.Equal(input, File.ReadAllBytes(outputPath));
    }

    [Fact]
    public void DefaultNamesAndOverwriteProtectionMatchTheJavaTools()
    {
        using var files = new TemporaryDirectory();
        string inputPath = files.PathFor("sample");
        string compressedPath = inputPath + ".zx1";
        byte[] input = TestData.Text();
        File.WriteAllBytes(inputPath, input);

        Assert.Equal(0, CompressorCli.Run([inputPath]));
        Assert.Equal(1, CompressorCli.Run([inputPath]));

        File.Delete(inputPath);
        Assert.Equal(0, DecompressorCli.Run([compressedPath]));
        Assert.Equal(input, File.ReadAllBytes(inputPath));
        Assert.Equal(1, DecompressorCli.Run([compressedPath]));
    }

    [Fact]
    public void InvalidOffsetOptionsReturnFailure()
    {
        Assert.Equal(1, CompressorCli.Run(["-m0"]));
        Assert.Equal(1, DecompressorCli.Run(["-m0"]));
    }

    [Fact]
    public void ExistingOutputDirectoriesAreProtectedLikeFiles()
    {
        using var files = new TemporaryDirectory();
        string inputPath = files.PathFor("input.bin");
        string compressedPath = files.PathFor("input.zx1");
        string compressorOutput = files.PathFor("compressed-output");
        string decompressorOutput = files.PathFor("decompressed-output");
        File.WriteAllBytes(inputPath, TestData.Text());
        Directory.CreateDirectory(compressorOutput);
        Directory.CreateDirectory(decompressorOutput);

        Assert.Equal(1, CompressorCli.Run([inputPath, compressorOutput]));
        Assert.Equal(0, CompressorCli.Run(["-f", inputPath, compressedPath]));
        Assert.Equal(1, DecompressorCli.Run([compressedPath, decompressorOutput]));
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly string path = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            $"jx1-csharp-tests-{Guid.NewGuid():N}");

        internal TemporaryDirectory()
        {
            Directory.CreateDirectory(path);
        }

        internal string PathFor(string name) => System.IO.Path.Combine(path, name);

        public void Dispose()
        {
            Directory.Delete(path, true);
        }
    }
}
