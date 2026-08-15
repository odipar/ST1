# nx1 for C#

`nx1` is the .NET 10 workbench for the ST1 project and a port of Java `jx1`.
It builds ST1-compatible ZX1 assets and independently mirrors the readable
compressor and resumable-decoder model used to verify the 68000 code.

## Build and test

Run these commands from the repository root with the .NET 10 SDK:

```sh
dotnet build csharp/Nx1.slnx -c Release
dotnet test csharp/Nx1.slnx -c Release
```

The tests cover the original-C golden streams, every Java behavior test,
operation limits, CLI round trips, malformed input, resuming, and ring-buffer
boundaries.

## Command-line tools

```sh
dotnet run --project csharp/src/Nx1.Cli -- [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
dotnet run --project csharp/src/Dnx1.Cli -- [-f] [-mN] input.zx1 [output]
```

The arguments have the same meaning as the
[Java tools](../README.md#jx1-java-tooling).
To produce app-host executables named `nx1` and `dnx1`:

```sh
dotnet publish csharp/src/Nx1.Cli -c Release
dotnet publish csharp/src/Dnx1.Cli -c Release
```

## API

The `Nx1` library exposes the same core types as the Java implementation:

```csharp
using Nx1;

Block optimal = Optimizer.Optimize(input, 0, global::Nx1.Nx1.MaxOffsetZx1);
Compressor.Result compressed = Compressor.Compress(optimal, input, 0, false);
byte[] restored = Decompressor.Decompress(compressed.Output);
```

`Decompressor.Decompress` collects a complete stream in memory. For bounded or
resumable output, derive from `Decompressor`, provide a ring buffer and chunk
size to its constructor, implement `Flip(byte[] buffer, int length)`, and call
`Resume()` until it returns `false`. Invalid streams throw
`InvalidDataException`; constructor argument errors use the standard argument
exceptions.

## Projects

| Project | Purpose |
|---|---|
| `src/Nx1` | Reusable compressor and decompressor library |
| `src/Nx1.Cli` | `nx1` compressor executable |
| `src/Dnx1.Cli` | `dnx1` decompressor executable |
| `tests/Nx1.Tests` | Compatibility and behavior tests |

## Origin and attribution

The ZX1 format and original C implementation were designed and implemented by
Einar Saukas (Copyright © 2021), with thanks to introspec/spke. The ST1 project
additions are Copyright © 2026 Robbert van Dalen. The Java implementation was
written by Claude (Anthropic's Claude Code), and this C# nx1 port by OpenAI
Codex, both under Robbert's direction. The port uses the repository's
[ST1/ZX1 dual license](../LICENSE).
