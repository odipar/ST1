// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

using System.Globalization;

namespace Jx1;

/// <summary>Shared command-line parsing and error-reporting helpers.</summary>
internal static class Cli
{
    /// <summary>Writes a C-compatible error message and returns the failure exit code.</summary>
    internal static int Error(string message)
    {
        Console.Error.WriteLine($"Error: {message}");
        return 1;
    }

    /// <summary>Writes usage text and returns the failure exit code.</summary>
    internal static int Usage(string text)
    {
        Console.Error.WriteLine(text);
        return 1;
    }

    /// <summary>
    /// Parses a signed decimal integer. Invalid or overflowing values become
    /// zero so callers reject them like the original C tool rejects <c>atoi() &lt;= 0</c>.
    /// </summary>
    internal static int ParseNumber(string value) =>
        int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int number)
            ? number
            : 0;

    /// <summary>Identifies filesystem exceptions that the CLIs report without a stack trace.</summary>
    internal static bool IsFileException(Exception exception) =>
        exception is IOException or UnauthorizedAccessException or ArgumentException
            or NotSupportedException;
}
