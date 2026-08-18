// ZX1 by Einar Saukas; C# port of the jx1 original by Claude (Anthropic's
// Claude Code) under Robbert van Dalen's direction. See LICENSE.

namespace Nx1;

/// <summary>
/// The progress report the optimal parsers print: an exact percentage of the
/// parse's inner-loop steps, and a time estimate fitted to how the parse has
/// been slowing down.
/// </summary>
/// <remarks>
/// The step count is exact and owes nothing to the data - position
/// <c>index</c> is tried against every offset from 1 to
/// <c>clamp(index, 1, offsetLimit)</c>, so the total is a closed form known
/// before the first step. What a step <em>costs</em> is another matter, so the
/// percentage measures progress, not remaining time. The estimate handles
/// time: elapsed is fitted as <c>a*x + b*x^2</c> in the percentage, through
/// the warm-up point, the midpoint and now - the square is what tracks a parse
/// that finds more matches, and so gets steadily slower, as it goes.
/// </remarks>
public sealed class ProgressMeter
{
    /// <summary>Percent of the work to finish before estimating anything,
    /// so the runtime's warm-up is not counted against the rest.</summary>
    private const int Warmup = 5;

    /// <summary>Percent of history the fit needs before it says anything: a
    /// curve drawn through three points a couple of percent apart is mostly
    /// noise, and a confidently wrong number is worse than no number.</summary>
    private const int Baseline = 15;

    private readonly bool _enabled;
    private readonly long _total;
    private readonly long _started;
    private readonly long[] _tickTimestamps = new long[101];
    private long _steps;
    private int _shown = -1;

    /// <summary>A meter over <paramref name="total"/> steps; disabled, it
    /// counts silently for callers that are not a person at a terminal.</summary>
    public ProgressMeter(long total, bool enabled)
    {
        _total = total;
        _enabled = enabled;
        _started = TimeProvider.System.GetTimestamp();
    }

    /// <summary>The parse's total steps: positions <paramref name="skip"/>
    /// through <paramref name="count"/> - 1, each against its window.</summary>
    public static long TotalSteps(int count, int skip, int offsetLimit) =>
        StepsBefore(count, offsetLimit) - StepsBefore(skip, offsetLimit);

    /// <summary>Steps spent on positions 0 through <paramref name="end"/> - 1.</summary>
    private static long StepsBefore(int end, int offsetLimit)
    {
        if (end <= 0)
        {
            return 0;
        }
        long ramp = Math.Min(end - 1L, offsetLimit);        // 1..ramp, one more each
        long flat = Math.Max(0L, end - 1L - offsetLimit);   // the rest, at the full window
        return 1 + ramp * (ramp + 1) / 2 + flat * offsetLimit;
    }

    /// <summary>Advances by one position's worth of steps and reports when the
    /// percent moves.</summary>
    public void Advance(long delta)
    {
        _steps += delta;
        if (!_enabled)
        {
            return;
        }
        int percent = (int)(_steps * 100 / _total);
        if (percent != _shown)
        {
            _shown = percent;
            long now = TimeProvider.System.GetTimestamp();
            _tickTimestamps[percent] = now;
            Console.Write($"\r[{percent,3}%] {Estimate(percent, now),-12}");
        }
    }

    /// <summary>The 100% line with the elapsed time; call once, when done.</summary>
    public void Finish()
    {
        if (_enabled)
        {
            long elapsed = TimeProvider.System.GetTimestamp() - _started;
            Console.WriteLine($"\r[100%] {Duration(elapsed),-12}");
        }
    }

    /// <summary>Time left, or "" until there is enough history to say.</summary>
    private string Estimate(int percent, long now)
    {
        int baseTick = Warmup;
        while (baseTick < percent && _tickTimestamps[baseTick] == 0)
        {
            baseTick++;                                 // a percent the loop stepped over
        }
        int mid = (baseTick + percent) / 2;
        while (mid > baseTick && _tickTimestamps[mid] == 0)
        {
            mid--;
        }
        if (mid <= baseTick || mid >= percent || percent - baseTick < Baseline)
        {
            return "";                                  // too little history to fit
        }
        double half = mid - baseTick;
        double span = percent - baseTick;
        double untilMid = _tickTimestamps[mid] - _tickTimestamps[baseTick];
        double untilNow = now - _tickTimestamps[baseTick];
        double square = (untilNow * half - untilMid * span) / (half * span * (span - half));
        double linear = (untilMid - square * half * half) / half;
        double whole = 100.0 - baseTick;
        double left = linear * whole + square * whole * whole - untilNow;
        if (!(left > 0))
        {
            return "";                                  // NaN, or already there
        }
        return Duration((long)left) + " left";
    }

    /// <summary>Seconds, in the shortest form that stays readable, rounded not
    /// floored.</summary>
    private static string Duration(long timestampDelta)
    {
        double frequency = TimeProvider.System.TimestampFrequency;
        long seconds = (long)Math.Round(Math.Max(0, timestampDelta) / frequency);
        return seconds < 60 ? $"{seconds}s" : $"{seconds / 60}m {seconds % 60:00}s";
    }
}
