namespace Nx1.Tests;

/// <summary>
/// The test fixtures in the Java suite use java.util.Random. System.Random
/// produces a different sequence, so keep the Java 48-bit LCG here.
/// </summary>
internal sealed class JavaRandom
{
    private const long Multiplier = 0x5DEECE66D;
    private const long Addend = 0xB;
    private const long Mask = (1L << 48) - 1;

    private long seed;

    internal JavaRandom(long seed)
    {
        this.seed = (seed ^ Multiplier) & Mask;
    }

    internal int NextInt(int bound)
    {
        if (bound <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bound));
        }

        if ((bound & -bound) == bound)
        {
            return (int)((bound * (long)Next(31)) >> 31);
        }

        int bits;
        int value;
        do
        {
            bits = Next(31);
            value = bits % bound;
        }
        while (unchecked(bits - value + (bound - 1)) < 0);

        return value;
    }

    internal void NextBytes(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        for (int index = 0; index < bytes.Length;)
        {
            int random = Next(32);
            for (int count = Math.Min(bytes.Length - index, sizeof(int)); count-- > 0; random >>= 8)
            {
                bytes[index++] = unchecked((byte)random);
            }
        }
    }

    private int Next(int bits)
    {
        seed = unchecked((seed * Multiplier + Addend) & Mask);
        return unchecked((int)(seed >> (48 - bits)));
    }
}
