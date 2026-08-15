# jx1 for C#

This is the .NET 10 port of jx1. It matches the Java compressor's ZX1 output
and provides the same resumable ring-buffer decompression model and CLI
options.

## Build and test

Run these commands from the repository root with the .NET 10 SDK:

```sh
dotnet build csharp/Jx1.slnx -c Release
dotnet test csharp/Jx1.slnx -c Release
```

The tests cover the original-C golden streams, every Java behavior test,
operation limits, CLI round trips, malformed input, resuming, and ring-buffer
boundaries.

## Command-line tools

```sh
dotnet run --project csharp/src/Jx1.Cli -- [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
dotnet run --project csharp/src/Djx1.Cli -- [-f] [-mN] input.zx1 [output]
```

The arguments have the same meaning as the [Java tools](../README.md#java-cli).
To produce app-host executables named `jx1` and `djx1`:

```sh
dotnet publish csharp/src/Jx1.Cli -c Release
dotnet publish csharp/src/Djx1.Cli -c Release
```

## API

The `Jx1` library exposes the same core types as the Java implementation:

```csharp
using Jx1;

Block optimal = Optimizer.Optimize(input, 0, global::Jx1.Jx1.MaxOffsetZx1);
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
| `src/Jx1` | Reusable compressor and decompressor library |
| `src/Jx1.Cli` | `jx1` compressor executable |
| `src/Djx1.Cli` | `djx1` decompressor executable |
| `tests/Jx1.Tests` | Compatibility and behavior tests |

## Origin and attribution

The ZX1 format and original C implementation were designed and implemented by
Einar Saukas (Copyright © 2021), with thanks to introspec/spke. The jx1
extensions are Copyright © 2026 Robbert van Dalen. The Java implementation was
written by Claude (Anthropic's Claude Code), and this C# port by OpenAI Codex,
both under Robbert's direction. The port uses the repository's
[ZX1/jx1 dual license](../LICENSE).
