// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Jx1;

/// <summary>Command-line ZX1 decompressor.</summary>
/// <remarks>
/// C# counterpart of the Java <c>Djx1</c> entry point, itself based on
/// <c>dzx1.c</c> from
/// <see href="https://github.com/einar-saukas/ZX1">ZX1</see> by Einar Saukas.
/// Output is streamed through the decoder's ring directly to the destination
/// file instead of being accumulated in memory.
/// </remarks>
public static class Djx1
{
    /// <summary>Runs the decompressor command.</summary>
    /// <param name="args">
    /// Arguments after the executable name. Syntax:
    /// <c>djx1 [-f] [-mN] input.zx1 [output]</c>.
    /// </param>
    /// <returns>Zero on success; one after a user-facing argument, file, or data error.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="args"/> is null.</exception>
    public static int Run(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        Console.WriteLine(
            "DJX1: Data decompressor v0.1 by Robbert van Dalen, "
            + "based on DZX1 v1.5: Data decompressor by Einar Saukas");

        // Process optional parameters.
        bool forcedMode = false;
        int bufferSize = Decompressor.DefaultBufferSize;
        int index = 0;
        for (; index < args.Length
            && args[index].StartsWith("-", StringComparison.Ordinal); index++)
        {
            if (args[index] == "-f")
            {
                forcedMode = true;
            }
            else if (args[index].StartsWith("-m", StringComparison.Ordinal))
            {
                bufferSize = Cli.ParseNumber(args[index][2..]);
                if (bufferSize <= 0)
                {
                    return Cli.Error($"Invalid parameter {args[index]}");
                }
            }
            else
            {
                return Cli.Error($"Invalid parameter {args[index]}");
            }
        }

        // Determine input and output filenames, inferring by removing .zx1.
        string inputName;
        string outputName;
        if (args.Length == index + 1)
        {
            inputName = args[index];
            if (inputName.Length > 4 && inputName.EndsWith(".zx1", StringComparison.Ordinal))
            {
                outputName = inputName[..^4];
            }
            else
            {
                return Cli.Error("Cannot infer output filename");
            }
        }
        else if (args.Length == index + 2)
        {
            inputName = args[index];
            outputName = args[index + 1];
        }
        else
        {
            return Cli.Usage(
                "Usage: djx1 [-f] [-mN] input.zx1 [output]\n"
                + "  -f      Force overwrite of output file\n"
                + "  -mN     Ring buffer of N bytes (default 65536); "
                + "N must cover the largest offset");
        }

        // Read the complete compressed stream; output itself remains streaming.
        byte[] input;
        // Send each ring flip straight to the buffered destination stream.
        try
        {
            input = File.ReadAllBytes(inputName);
        }
        catch (Exception exception) when (Cli.IsFileException(exception))
        {
            return Cli.Error($"Cannot access input file {inputName}");
        }
        if (input.Length == 0)
        {
            return Cli.Error($"Empty input file {inputName}");
        }
        if (!forcedMode && Path.Exists(outputName))
        {
            return Cli.Error($"Already existing output file {outputName}");
        }

        try
        {
            using var file = new FileStream(outputName, FileMode.Create, FileAccess.Write, FileShare.None);
            using var output = new BufferedStream(file);
            new FileDecompressor(input, new byte[bufferSize], output).Decompress();
        }
        catch (InvalidDataException exception)
        {
            return Cli.Error($"{exception.Message} {inputName}");
        }
        catch (Exception exception) when (Cli.IsFileException(exception))
        {
            return Cli.Error($"Cannot write output file {outputName}");
        }

        try
        {
            Console.WriteLine(
                $"File decompressed from {input.Length} to {new FileInfo(outputName).Length} bytes!");
        }
        catch (Exception exception) when (Cli.IsFileException(exception))
        {
            return Cli.Error($"Cannot write output file {outputName}");
        }
        return 0;
    }

    private sealed class FileDecompressor : Decompressor
    {
        private readonly Stream output;

        internal FileDecompressor(byte[] input, byte[] buffer, Stream output)
            : base(input, buffer)
        {
            this.output = output;
        }

        protected override void Flip(byte[] buffer, int length) =>
            output.Write(buffer, 0, length);
    }
}
