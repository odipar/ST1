// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Jx1;

/// <summary>
/// Optimal LZ parser for the ZX1 format.
/// </summary>
/// <remarks>
/// This is the C# counterpart of the Java <c>Optimizer</c>, itself a port of
/// <c>optimize.c</c> from
/// <see href="https://github.com/einar-saukas/ZX1">ZX1</see> by Einar Saukas.
/// It returns a linked optimal parse; <see cref="Compressor"/> turns that parse
/// into a ZX1 bitstream.
/// </remarks>
public static class Optimizer
{
    /// <summary>The format's initial last-offset value.</summary>
    public const int InitialOffset = 1;

    private const int MaxScale = 50;

    /// <summary>Finds the minimum-bit parse of <paramref name="input"/>.</summary>
    /// <param name="input">Complete source data; it must not be empty.</param>
    /// <param name="skip">
    /// Number of leading bytes excluded from the compressed output. They remain
    /// available as match history, matching the command-line skip mode.
    /// </param>
    /// <param name="offsetLimit">
    /// Largest permitted back-reference distance, from one through
    /// <see cref="Jx1.MaxOffsetZx1"/>. Backwards encoding is limited to one less.
    /// </param>
    /// <returns>The final block of a chain whose first node is the parser's fake head.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="input"/> is null.</exception>
    /// <exception cref="ArgumentException"><paramref name="input"/> is empty.</exception>
    /// <exception cref="ArgumentOutOfRangeException">
    /// <paramref name="skip"/> is outside the input, or <paramref name="offsetLimit"/>
    /// is outside the format's supported range.
    /// </exception>
    public static Block Optimize(byte[] input, int skip, int offsetLimit)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (input.Length == 0)
        {
            throw new ArgumentException("Input must not be empty", nameof(input));
        }
        if (skip < 0 || skip >= input.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(skip));
        }
        if (offsetLimit < InitialOffset || offsetLimit > Jx1.MaxOffsetZx1)
        {
            throw new ArgumentOutOfRangeException(nameof(offsetLimit));
        }

        int maxOffset = OffsetCeiling(input.Length - 1, offsetLimit);
        var lastLiteral = new Block?[maxOffset + 1];
        var lastMatch = new Block?[maxOffset + 1];
        var optimal = new Block?[input.Length];
        var matchLength = new int[maxOffset + 1];
        var bestLength = new int[Math.Max(input.Length, 3)];
        bestLength[2] = 2;

        // Fake block for the first real block to chain from.
        lastMatch[InitialOffset] = new Block(-1, skip - 1, InitialOffset, null);

        Console.Write('[');
        int dots = 2;

        for (int index = skip; index < input.Length; index++)
        {
            int bestLengthSize = 2;
            maxOffset = OffsetCeiling(index, offsetLimit);
            for (int offset = 1; offset <= maxOffset; offset++)
            {
                if (index != skip && index >= offset && input[index] == input[index - offset])
                {
                    // Match from the last offset after a literal run.
                    Block? literal = lastLiteral[offset];
                    if (literal is not null)
                    {
                        int length = index - literal.Index;
                        int literalBits = literal.Bits + 1 + EliasGammaBits(length);
                        var match = new Block(literalBits, index, offset, literal);
                        lastMatch[offset] = match;
                        optimal[index] = Better(optimal[index], match);
                    }

                    // Match from a newly encoded offset; its minimum length is two.
                    if (++matchLength[offset] > 1)
                    {
                        if (bestLengthSize < matchLength[offset])
                        {
                            Block best = optimal[index - bestLength[bestLengthSize]]
                                ?? throw new InvalidOperationException("Incomplete optimal parse");
                            int bits = best.Bits + EliasGammaBits(bestLength[bestLengthSize] - 1);
                            do
                            {
                                bestLengthSize++;
                                Block shorter = optimal[index - bestLengthSize]
                                    ?? throw new InvalidOperationException("Incomplete optimal parse");
                                int shorterBits = shorter.Bits + EliasGammaBits(bestLengthSize - 1);
                                if (shorterBits <= bits)
                                {
                                    bestLength[bestLengthSize] = bestLengthSize;
                                    bits = shorterBits;
                                }
                                else
                                {
                                    bestLength[bestLengthSize] = bestLength[bestLengthSize - 1];
                                }
                            }
                            while (bestLengthSize < matchLength[offset]);
                        }

                        int length = bestLength[matchLength[offset]];
                        Block previous = optimal[index - length]
                            ?? throw new InvalidOperationException("Incomplete optimal parse");
                        int matchBits = previous.Bits + 1 + (offset > 128 ? 16 : 8)
                            + EliasGammaBits(length - 1);
                        Block? match = lastMatch[offset];
                        if (match is null || match.Index != index || match.Bits > matchBits)
                        {
                            match = new Block(matchBits, index, offset, previous);
                            lastMatch[offset] = match;
                            optimal[index] = Better(optimal[index], match);
                        }
                    }
                }
                else
                {
                    // Extend a literal run after the most recent match at this offset.
                    matchLength[offset] = 0;
                    Block? match = lastMatch[offset];
                    if (match is not null)
                    {
                        int length = index - match.Index;
                        int literalBits = match.Bits + 1 + EliasGammaBits(length) + length * 8;
                        var literal = new Block(literalBits, index, 0, match);
                        lastLiteral[offset] = literal;
                        optimal[index] = Better(optimal[index], literal);
                    }
                }
            }

            if ((long)index * MaxScale / input.Length > dots)
            {
                Console.Write('.');
                Console.Out.Flush();
                dots++;
            }
        }

        Console.WriteLine(']');
        return optimal[^1] ?? throw new InvalidOperationException("Incomplete optimal parse");
    }

    private static int OffsetCeiling(int index, int offsetLimit) =>
        Math.Clamp(index, InitialOffset, offsetLimit);

    private static int EliasGammaBits(int value)
    {
        int bits = 1;
        while ((value >>= 1) != 0)
        {
            bits += 2;
        }
        return bits;
    }

    private static Block Better(Block? current, Block candidate) =>
        current is null || current.Bits > candidate.Bits ? candidate : current;
}
