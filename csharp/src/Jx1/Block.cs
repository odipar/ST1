// ZX1 by Einar Saukas; C# port by OpenAI Codex under Robbert van Dalen's direction.
// See LICENSE for the dual-license terms and full attribution.

namespace Jx1;

/// <summary>
/// One block (literal run or match) in an optimal-parse chain.
/// An <see cref="Offset"/> of zero denotes literals.
/// </summary>
/// <remarks>
/// The original C implementation in <c>zx1.h</c> and <c>memory.c</c> manages
/// blocks with a reference-counting pool. The managed implementations can use
/// ordinary immutable objects instead.
/// </remarks>
/// <param name="Bits">Total encoded bit cost through this block.</param>
/// <param name="Index">Inclusive input index at which this block ends.</param>
/// <param name="Offset">Zero for literals; otherwise the match distance.</param>
/// <param name="Chain">The preceding block, or <see langword="null"/> for the parser's fake head.</param>
public sealed record Block(int Bits, int Index, int Offset, Block? Chain);
