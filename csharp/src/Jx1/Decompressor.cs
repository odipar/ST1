// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Jx1;

/// <summary>
/// Resumable ZX1 decompressor with bounded-memory ring-buffer output.
/// </summary>
/// <remarks>
/// <para>
/// This is the C# counterpart of the Java <c>Decompressor</c>, itself based on
/// <c>dzx1.c</c> from
/// <see href="https://github.com/einar-saukas/ZX1">ZX1</see> by Einar Saukas.
/// Output passes through a caller-supplied ring, so memory use is bounded by
/// the ring rather than the decompressed size. A ring of N bytes supports
/// back-references through N bytes; <see cref="Flip(byte[], int)"/> decides
/// where completed spans go.
/// </para>
/// <para>
/// Decompression is resumable: <see cref="Resume"/> emits at most the chunk
/// size supplied at construction and returns control to the caller. Instance
/// <see cref="Decompress()"/> resets and drains the stream; the static overloads
/// collect it in memory.
/// </para>
/// <para>
/// Malformed streams throw <see cref="InvalidDataException"/>. Unlike Java
/// assertions, these checks remain active in Release builds.
/// </para>
/// </remarks>
public abstract class Decompressor
{
    /// <summary>
    /// Ring size used by the in-memory overload; it covers the full ZX1 offset range.
    /// </summary>
    public const int DefaultBufferSize = 65_536;

    /// <summary>The operation currently emitting bytes; headers are parsed between operations.</summary>
    private enum State
    {
        Start,
        Literals,
        Match,
        Done,
    }

    private readonly byte[] input;
    private readonly byte[] buffer;
    private readonly int chunkSize;
    private int inputIndex;
    private int bitMask;
    private int bitValue;
    private int bufferIndex;
    private long flushedSize;
    private int lastOffset;
    private int remaining;
    private State state;

    /// <summary>Creates a decompressor whose resume chunk is the ring size.</summary>
    /// <param name="input">Complete ZX1 input stream.</param>
    /// <param name="buffer">Nonempty caller-owned ring buffer.</param>
    /// <exception cref="ArgumentNullException">Either array is null.</exception>
    /// <exception cref="ArgumentException"><paramref name="buffer"/> is empty.</exception>
    protected Decompressor(byte[] input, byte[] buffer)
        : this(input, buffer, buffer?.Length ?? 0)
    {
    }

    /// <summary>Creates a decompressor with an explicit resume chunk size.</summary>
    /// <param name="input">Complete ZX1 input stream.</param>
    /// <param name="buffer">Nonempty caller-owned ring buffer.</param>
    /// <param name="chunkSize">Positive maximum output bytes produced by one <see cref="Resume"/> call.</param>
    /// <exception cref="ArgumentNullException">Either array is null.</exception>
    /// <exception cref="ArgumentException"><paramref name="buffer"/> is empty.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><paramref name="chunkSize"/> is not positive.</exception>
    protected Decompressor(byte[] input, byte[] buffer, int chunkSize)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(buffer);
        if (buffer.Length == 0)
        {
            throw new ArgumentException("Empty ring buffer", nameof(buffer));
        }
        if (chunkSize <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(chunkSize), "Chunk size must be positive");
        }

        this.input = input;
        this.buffer = buffer;
        this.chunkSize = chunkSize;
        Reset();
    }

    /// <summary>
    /// Consumes the first <paramref name="length"/> bytes of the ring buffer.
    /// Called for each full buffer and once for a nonempty final remainder.
    /// </summary>
    /// <remarks>
    /// The callback is synchronous and the ring is reused immediately afterward;
    /// consume or copy the span before returning. Do not modify the ring: its
    /// bytes remain match history for later back-references.
    /// </remarks>
    /// <param name="buffer">The same ring supplied at construction.</param>
    /// <param name="length">Number of valid bytes starting at index zero.</param>
    protected abstract void Flip(byte[] buffer, int length);

    /// <summary>Decompresses a complete ZX1 stream in memory.</summary>
    /// <param name="input">Complete ZX1 stream with no trailing bytes.</param>
    /// <returns>The decompressed bytes.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="input"/> is null.</exception>
    /// <exception cref="InvalidDataException">The stream is malformed or truncated.</exception>
    public static byte[] Decompress(byte[] input) =>
        Decompress(input, new byte[DefaultBufferSize]);

    /// <summary>Decompresses a complete ZX1 stream through the supplied ring.</summary>
    /// <param name="input">Complete ZX1 stream with no trailing bytes.</param>
    /// <param name="buffer">Nonempty ring whose size covers every encoded offset.</param>
    /// <returns>The decompressed bytes.</returns>
    /// <exception cref="ArgumentNullException">Either array is null.</exception>
    /// <exception cref="ArgumentException"><paramref name="buffer"/> is empty.</exception>
    /// <exception cref="InvalidDataException">
    /// The stream is malformed, truncated, has trailing bytes, or references beyond the ring.
    /// </exception>
    public static byte[] Decompress(byte[] input, byte[] buffer)
    {
        var collector = new MemoryCollector(input, buffer);
        collector.Decompress();
        return collector.ToArray();
    }

    /// <summary>
    /// Resets and drains the complete stream. An instance may be reused; each
    /// call starts again at the beginning of its input.
    /// </summary>
    /// <exception cref="InvalidDataException">The stream is invalid.</exception>
    public void Decompress()
    {
        Reset();
        while (Resume())
        {
        }
    }

    /// <summary>
    /// Produces at most one configured chunk. Returns <see langword="false"/>
    /// once the stream is complete.
    /// </summary>
    /// <returns>
    /// <see langword="true"/> when more output remains; otherwise
    /// <see langword="false"/>. Calls after completion remain false.
    /// </returns>
    /// <exception cref="InvalidDataException">The stream is invalid.</exception>
    public bool Resume()
    {
        int budget = chunkSize;
        while (state != State.Done)
        {
            if (remaining == 0)
            {
                Next();
            }
            else if (budget == 0)
            {
                return true;
            }
            else
            {
                WriteByte(state == State.Literals ? ReadByte() : ReadBufferByte());
                remaining--;
                budget--;
            }
        }
        return false;
    }

    private void Reset()
    {
        inputIndex = 0;
        bitMask = 0;
        bitValue = 0;
        bufferIndex = 0;
        flushedSize = 0;
        lastOffset = Optimizer.InitialOffset;
        remaining = 0;
        state = State.Start;
    }

    private void Next()
    {
        // The state machine is the structured equivalent of dzx1.c's goto graph.
        switch (state)
        {
            case State.Start:
                BeginLiterals();
                break;
            case State.Literals:
                if (ReadBit())
                {
                    BeginMatchFromNewOffset();
                }
                else
                {
                    BeginMatchFromLastOffset();
                }
                break;
            case State.Match:
                if (ReadBit())
                {
                    BeginMatchFromNewOffset();
                }
                else
                {
                    BeginLiterals();
                }
                break;
            default:
                throw new InvalidOperationException("Cannot advance a completed stream");
        }
    }

    private void BeginLiterals()
    {
        remaining = ReadInterlacedEliasGamma();
        Require(remaining > 0, "Invalid data in input file");
        state = State.Literals;
    }

    private void BeginMatchFromLastOffset()
    {
        remaining = ReadInterlacedEliasGamma();
        Require(remaining > 0, "Invalid data in input file");
        CheckOffset();
        state = State.Match;
    }

    private void BeginMatchFromNewOffset()
    {
        int offset = ReadOffset();
        if (offset <= 0)
        {
            if (bufferIndex != 0)
            {
                Flip(buffer, bufferIndex);
            }
            Require(inputIndex == input.Length, "Input file too long");
            state = State.Done;
            return;
        }

        lastOffset = offset;
        remaining = unchecked(ReadInterlacedEliasGamma() + 1);
        Require(remaining > 0, "Invalid data in input file");
        CheckOffset();
        state = State.Match;
    }

    private void CheckOffset()
    {
        Require(lastOffset <= flushedSize + bufferIndex, "Invalid data in input file");
        Require(lastOffset <= buffer.Length, "Backreference beyond ring buffer in input file");
    }

    private int ReadOffset()
    {
        int offset = ReadByte();
        if ((offset & 1) != 0)
        {
            int high = ReadByte();
            return 32_512 - (high & 254) * 128 - (offset & 254) - (high & 1);
        }
        return 128 - offset / 2;
    }

    private int ReadByte()
    {
        if (inputIndex >= input.Length)
        {
            throw new InvalidDataException(input.Length == 0
                ? "Empty input file"
                : "Truncated input file");
        }
        return input[inputIndex++];
    }

    private bool ReadBit()
    {
        bitMask >>= 1;
        if (bitMask == 0)
        {
            bitMask = 128;
            bitValue = ReadByte();
        }
        return (bitValue & bitMask) != 0;
    }

    private int ReadInterlacedEliasGamma()
    {
        int value = 1;
        while (ReadBit())
        {
            value = unchecked((value << 1) | (ReadBit() ? 1 : 0));
        }
        return value;
    }

    private int ReadBufferByte()
    {
        int index = bufferIndex - lastOffset;
        return buffer[index >= 0 ? index : buffer.Length + index];
    }

    private void WriteByte(int value)
    {
        buffer[bufferIndex++] = unchecked((byte)value);
        if (bufferIndex == buffer.Length)
        {
            Flip(buffer, bufferIndex);
            flushedSize += bufferIndex;
            bufferIndex = 0;
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidDataException(message);
        }
    }

    private sealed class MemoryCollector : Decompressor
    {
        private readonly MemoryStream output = new();

        internal MemoryCollector(byte[] input, byte[] buffer)
            : base(input, buffer)
        {
        }

        internal byte[] ToArray() => output.ToArray();

        protected override void Flip(byte[] buffer, int length) =>
            output.Write(buffer, 0, length);
    }
}
