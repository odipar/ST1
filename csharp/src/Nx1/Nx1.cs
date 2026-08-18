// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Nx1;

/// <summary>Command-line ZX1 compressor.</summary>
/// <remarks>
/// <c>Nx1</c> is the C# counterpart of the Java <c>Jx1</c> entry point,
/// itself a port of
/// <c>zx1.c</c> from
/// <see href="https://github.com/einar-saukas/ZX1">ZX1</see> by Einar Saukas.
/// It adds configurable offset and operation-length limits while preserving
/// the ZX1 bitstream format.
/// </remarks>
public static class Nx1
{
    /// <summary>Largest back-reference representable by the ZX1 format.</summary>
    public const int MaxOffsetZx1 = 32_512;

    /// <summary>Offset limit used by quick mode, matching ZX7's window.</summary>
    public const int MaxOffsetZx7 = 2_176;

    /// <summary>Largest operation length representable by the ST1 decoders.</summary>
    public const int MaxOpSt1 = 65_535;

    /// <summary>Runs the compressor command.</summary>
    /// <param name="args">
    /// Arguments after the executable name. Syntax:
    /// <c>nx1 [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]</c>.
    /// A positive <c>+N</c> argument skips N leading source bytes.
    /// </param>
    /// <returns>Zero on success; one after a user-facing argument or file error.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="args"/> is null.</exception>
    public static int Run(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        Console.WriteLine(
            "NX1: Optimal data compressor v1.0 by Robbert van Dalen, "
            + "based on ZX1 v1.5: Optimal data compressor by Einar Saukas");

        // Process optional parameters.
        int skip = 0;
        int maxOffset = 0;
        int maxOpLength = int.MaxValue;
        bool forcedMode = false;
        bool quickMode = false;
        bool backwardsMode = false;
        int index = 0;
        for (; index < args.Length
            && (args[index].StartsWith("-", StringComparison.Ordinal)
                || args[index].StartsWith("+", StringComparison.Ordinal)); index++)
        {
            switch (args[index])
            {
                case "-f":
                    forcedMode = true;
                    break;
                case "-b":
                    backwardsMode = true;
                    break;
                case "-q":
                    quickMode = true;
                    break;
                default:
                    if (args[index].StartsWith("-m", StringComparison.Ordinal))
                    {
                        maxOffset = Cli.ParseNumber(args[index][2..]);
                        if (maxOffset <= 0)
                        {
                            return Cli.Error($"Invalid parameter {args[index]}");
                        }
                    }
                    else if (args[index].StartsWith("-l", StringComparison.Ordinal))
                    {
                        maxOpLength = Cli.ParseNumber(args[index][2..]);
                        if (maxOpLength <= 0)
                        {
                            return Cli.Error($"Invalid parameter {args[index]}");
                        }
                    }
                    else
                    {
                        skip = Cli.ParseNumber(args[index]);
                        if (skip <= 0)
                        {
                            return Cli.Error($"Invalid parameter {args[index]}");
                        }
                    }
                    break;
            }
        }

        if (maxOffset > MaxOffsetZx1 - (backwardsMode ? 1 : 0))
        {
            return Cli.Error($"Invalid parameter -m{maxOffset}");
        }

        // Determine the output filename.
        string outputName;
        if (args.Length == index + 1)
        {
            outputName = args[index] + ".zx1";
        }
        else if (args.Length == index + 2)
        {
            outputName = args[index + 1];
        }
        else
        {
            return Cli.Usage(
                "Usage: nx1 [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]\n"
                + "  -f      Force overwrite of output file\n"
                + "  -b      Compress backwards\n"
                + "  -q      Quick: event-driven parsing - the same packed\n"
                + "          size, but not byte-identical to zx1's output\n"
                + "  -mN     Limit backreference offsets to N bytes\n"
                + "  -lN     Split matches so no operation exceeds N bytes\n"
                + "          (use -l65535 for the ST1 decoders)");
        }
        string inputName = args[index];

        // Read and validate the input before touching the output.
        byte[] input;
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
        if (skip >= input.Length)
        {
            return Cli.Error($"Skipping entire input file {inputName}");
        }
        if (!forcedMode && Path.Exists(outputName))
        {
            return Cli.Error($"Already existing output file {outputName}");
        }

        // Reverse around the backwards encoder. -q keeps the full window and
        // the exact optimum - the event-driven parser packs to the same size -
        // but its ties fall differently, so only the default path is
        // byte-identical to the reference compressor. The old meaning, zx1's
        // reduced ZX7 window, is one -m2176 away.
        if (backwardsMode)
        {
            Array.Reverse(input);
        }
        int offsetLimit = maxOffset > 0
            ? maxOffset
            : MaxOffsetZx1 - (backwardsMode ? 1 : 0);
        Block parse = quickMode
            ? EventOptimizer.Optimize(input, skip, offsetLimit)
            : FastOptimizer.Optimize(input, skip, offsetLimit);
        Compressor.Result result = Compressor.Compress(
            parse,
            input,
            skip,
            backwardsMode,
            maxOpLength);
        byte[] output = result.Output;
        if (backwardsMode)
        {
            Array.Reverse(output);
        }

        // Write only the trimmed stream returned by Compressor.
        try
        {
            File.WriteAllBytes(outputName, output);
        }
        catch (Exception exception) when (Cli.IsFileException(exception))
        {
            return Cli.Error($"Cannot write output file {outputName}");
        }

        Console.WriteLine(
            $"File{(skip != 0 ? " partially" : string.Empty)} compressed"
            + $"{(backwardsMode ? " backwards" : string.Empty)} from "
            + $"{input.Length - skip} to {output.Length} bytes! (delta {result.Delta})");
        if (result.LongestOp > maxOpLength)
        {
            Console.WriteLine(
                $"Warning: longest operation is {result.LongestOp} bytes, over the "
                + $"-l{maxOpLength} limit: a literal run, which the format cannot split");
        }
        return 0;
    }
}
