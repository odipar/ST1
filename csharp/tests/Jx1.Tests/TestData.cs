using System.Text;

namespace Jx1.Tests;

/// <summary>Deterministic samples shared by the tests and Java golden vectors.</summary>
internal static class TestData
{
    internal static byte[] Text() =>
        Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat(
            "abracadabra hocus pocus abracadabra ",
            10)));

    internal static byte[] FarMatch()
    {
        var block = new byte[200];
        new JavaRandom(1).NextBytes(block);

        using var output = new MemoryStream();
        output.Write(block);
        output.Write(Enumerable.Repeat((byte)'x', 2_500).ToArray());
        output.Write(block);
        return output.ToArray();
    }

    internal static byte[] WordSoup()
    {
        var random = new JavaRandom(42);
        var words = new byte[20][];
        for (int index = 0; index < words.Length; index++)
        {
            words[index] = new byte[3 + random.NextInt(7)];
            random.NextBytes(words[index]);
        }

        using var output = new MemoryStream();
        for (int index = 0; index < 400; index++)
        {
            output.Write(words[random.NextInt(words.Length)]);
            output.WriteByte((byte)' ');
        }
        return output.ToArray();
    }
}
