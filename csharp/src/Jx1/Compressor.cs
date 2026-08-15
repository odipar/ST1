// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Jx1;

/// <summary>ZX1 bitstream writer.</summary>
/// <remarks>
/// This is the C# counterpart of the Java <c>Compressor</c>, itself a port of
/// <c>compress.c</c> from
/// <see href="https://github.com/einar-saukas/ZX1">ZX1</see> by Einar Saukas.
/// Supply the parse returned by <see cref="Optimizer.Optimize(byte[], int, int)"/>;
/// the compressor preserves the format and produces byte-identical output to
/// the Java implementation, and to the original C implementation in their
/// shared modes.
/// </remarks>
public sealed class Compressor
{
    /// <summary>
    /// A compressed stream, the delta required for safe in-place decompression,
    /// and the longest emitted operation.
    /// </summary>
    /// <param name="Output">The complete encoded ZX1 stream.</param>
    /// <param name="Delta">Extra separation required for safe in-place decompression.</param>
    /// <param name="LongestOp">Longest literal run or match emitted into the stream.</param>
    public sealed record Result(byte[] Output, int Delta, int LongestOp);

    private readonly byte[] input;
    private readonly byte[] output;
    private int inputIndex;
    private int outputIndex;
    private int bitIndex;
    private int bitMask;
    private int diff;
    private int delta;
    private int longestOp;

    private Compressor(byte[] input, byte[] output, int skip)
    {
        this.input = input;
        this.output = output;
        inputIndex = skip;
        diff = output.Length - input.Length + skip;
    }

    /// <summary>Compresses an optimal parse without limiting operation lengths.</summary>
    /// <param name="optimal">Final block of the parse returned by <see cref="Optimizer"/>.</param>
    /// <param name="input">The source bytes used to construct that parse.</param>
    /// <param name="skip">Leading source bytes omitted from the compressed output.</param>
    /// <param name="backwardsMode">
    /// Whether to use ZX1's backwards offset encoding. Library callers mirror
    /// the CLI by reversing the input before optimization and the output afterward.
    /// </param>
    /// <returns>The encoded stream and its in-place-decompression metadata.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="optimal"/> or <paramref name="input"/> is null.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="skip"/> is outside the input.</exception>
    public static Result Compress(Block optimal, byte[] input, int skip, bool backwardsMode) =>
        Compress(optimal, input, skip, backwardsMode, int.MaxValue);

    /// <summary>
    /// Compresses an optimal parse while limiting operation lengths where the
    /// format permits.
    /// </summary>
    /// <remarks>
    /// When <paramref name="maxOpLength"/> is at least three, longer matches are
    /// emitted as several matches at the same offset. Smaller requested limits
    /// can be exceeded because ZX1 cannot encode a one-byte new-offset match.
    /// Literal runs also cannot be split because the format has no transition
    /// for one literal run immediately followed by another.
    /// <see cref="Result.LongestOp"/> therefore reports the actual maximum so
    /// callers targeting the 68000 decoder can detect either case.
    /// </remarks>
    /// <param name="optimal">Final block of the parse returned by <see cref="Optimizer"/>.</param>
    /// <param name="input">The source bytes used to construct that parse.</param>
    /// <param name="skip">Leading source bytes omitted from the compressed output.</param>
    /// <param name="backwardsMode">
    /// Whether to use ZX1's backwards offset encoding. This method does not
    /// reverse either array; see the shorter overload for the caller contract.
    /// </param>
    /// <param name="maxOpLength">Positive maximum length requested for each operation.</param>
    /// <returns>The encoded stream and its in-place-decompression metadata.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="optimal"/> or <paramref name="input"/> is null.</exception>
    /// <exception cref="ArgumentOutOfRangeException">
    /// <paramref name="skip"/> is outside the input, or <paramref name="maxOpLength"/> is not positive.
    /// </exception>
    public static Result Compress(
        Block optimal,
        byte[] input,
        int skip,
        bool backwardsMode,
        int maxOpLength)
    {
        ArgumentNullException.ThrowIfNull(optimal);
        ArgumentNullException.ThrowIfNull(input);
        if (skip < 0 || skip >= input.Length)
        {
            throw new ArgumentOutOfRangeException(nameof(skip));
        }
        if (maxOpLength <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxOpLength));
        }

        int size = (optimal.Bits + 24) / 8 + SplitHeadroom(optimal, maxOpLength);
        return new Compressor(input, new byte[size], skip)
            .Run(optimal, backwardsMode, maxOpLength);
    }

    private static int SplitHeadroom(Block optimal, int maxOpLength)
    {
        int extra = 0;
        for (Block? block = optimal; block?.Chain is not null; block = block.Chain)
        {
            if (block.Offset != 0)
            {
                extra += (block.Index - block.Chain.Index - 1) / maxOpLength;
            }
        }
        return extra * 8;
    }

    private Result Run(Block optimal, bool backwardsMode, int maxOpLength)
    {
        // Un-reverse the parse chain. Its first node is the parser's fake head.
        var blocks = new Stack<Block>();
        for (Block? block = optimal; block is not null; block = block.Chain)
        {
            blocks.Push(block);
        }
        Block previous = blocks.Pop();

        int lastOffset = Optimizer.InitialOffset;
        bool first = true;
        // The format's meaning for a zero transition bit depends on the state:
        // after literals it means a match at the last offset; after a match it
        // means literals. Split matches may consequently have to name the same
        // offset again rather than assuming the short form.
        bool afterLiterals = false;

        foreach (Block block in blocks)
        {
            int length = block.Index - previous.Index;
            previous = block;

            if (block.Offset == 0)
            {
                if (first)
                {
                    first = false;
                }
                else
                {
                    WriteBit(false);
                }

                WriteInterlacedEliasGamma(length);
                for (int i = 0; i < length; i++)
                {
                    WriteByte(input[inputIndex]);
                    ReadBytes(1);
                }
                afterLiterals = true;
                longestOp = Math.Max(longestOp, length);
                continue;
            }

            int offset = block.Offset;
            // Split evenly. A greedy split can leave a one-byte new-offset
            // match, which the format cannot encode; even pieces are all at
            // least two bytes when maxOpLength is at least three.
            int pieces = maxOpLength < 3 ? 1 : (length - 1) / maxOpLength + 1;
            int baseLength = length / pieces;
            int wider = length % pieces;
            for (int i = 0; i < pieces; i++)
            {
                int piece = baseLength + (i < wider ? 1 : 0);
                if (afterLiterals && offset == lastOffset)
                {
                    WriteBit(false);
                    WriteInterlacedEliasGamma(piece);
                    ReadBytes(piece);
                    afterLiterals = false;
                }
                else
                {
                    WriteBit(true);
                    if (backwardsMode)
                    {
                        if (offset > 128)
                        {
                            WriteByte(((offset - 1) & 254) + 1);
                            WriteByte(offset / 256 * 2 + (offset - 1) % 2 + 2);
                        }
                        else
                        {
                            WriteByte((offset - 1) * 2);
                        }
                    }
                    else if (offset > 128)
                    {
                        WriteByte(255 - ((offset - 1) & 254));
                        WriteByte(252 - (offset - 1) / 256 * 2 + offset % 2);
                    }
                    else
                    {
                        WriteByte(256 - offset * 2);
                    }

                    WriteInterlacedEliasGamma(piece - 1);
                    ReadBytes(piece);
                    lastOffset = offset;
                    afterLiterals = false;
                }
                longestOp = Math.Max(longestOp, piece);
            }
        }

        // End marker.
        WriteBit(true);
        if (backwardsMode)
        {
            WriteByte(1);
            WriteByte(0);
        }
        else
        {
            WriteByte(255);
            WriteByte(255);
        }

        // The working buffer includes parse and split headroom. Trim it only
        // after computing the unused capacity so Delta remains exact.
        int over = output.Length - outputIndex;
        var trimmed = new byte[outputIndex];
        Array.Copy(output, trimmed, outputIndex);
        return new Result(trimmed, Math.Max(0, delta - over), longestOp);
    }

    private void ReadBytes(int count)
    {
        inputIndex += count;
        diff += count;
        delta = Math.Max(delta, diff);
    }

    private void WriteByte(int value)
    {
        output[outputIndex++] = unchecked((byte)value);
        diff--;
    }

    private void WriteBit(bool value)
    {
        if (bitMask == 0)
        {
            bitMask = 128;
            bitIndex = outputIndex;
            WriteByte(0);
        }
        if (value)
        {
            output[bitIndex] |= unchecked((byte)bitMask);
        }
        bitMask >>= 1;
    }

    private void WriteInterlacedEliasGamma(int value)
    {
        int highBit = 1;
        while (highBit <= value / 2)
        {
            highBit <<= 1;
        }
        for (int bit = highBit >> 1; bit != 0; bit >>= 1)
        {
            WriteBit(true);
            WriteBit((value & bit) != 0);
        }
        WriteBit(false);
    }
}
