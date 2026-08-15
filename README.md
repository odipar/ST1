# ST1 — streaming ZX1 decompression for the Atari ST

Keep assets packed. Spend the RAM on the demo.

ST1 is a small [ZX1](https://github.com/einar-saukas/ZX1) decompressor for the
plain 68000. It can stop after a chosen number of output bytes and continue
later. The ring version reuses a small buffer even when the full output is much
larger. This makes it useful for loaders, effects, music, and other work that
must share each video frame.

## 68000 decoders

ST1 has two versions of the same decoder. Both read normal ZX1 data, run on a
plain 68000, and keep their current position in five registers. Your code can
set a maximum number of output bytes, stop, do other work, and continue later.

| File | Code | Use | Calls |
|---|---:|---|---|
| [ST1.S](68k/ST1.S) | 208 B | the whole output stays in one buffer | `ST1_init`, `ST1_decompress`, `ST1_resume` |
| [ST1_ring.S](68k/ST1_ring.S) | 266 B | output passes through a ring supplied by your code | `ST1_init`, `ST1_resume` |

Use [ST1.S](68k/ST1.S) when the whole output fits in memory. It can decode the
whole file with one call or stop and resume. Use
[ST1_ring.S](68k/ST1_ring.S) when memory is tight. It reuses a fixed buffer;
your code uses each returned block before asking for more.

### Trusted input only

The decoders do not check the input, buffer, or arguments. Bad data can read or
write outside the buffers. Use trusted files made at build time, or validate
them before decoding.

- Compress with `-l65535`. A longer match is split. A longer literal run cannot
  be split; the compressor warns about it, and that file is not safe for ST1.
- A resume limit must be from 1 to 65535. Zero makes no progress.
- A ring may be from 1 to 65535 bytes. For a ring smaller than 32512 bytes,
  compress that stream with the matching `-mN`.
- Keep the input, output, and saved registers valid until decoding ends.

### Calls and registers

Keep these five values between calls:

| Register | Meaning |
|---|---|
| `a0.l` | packed input position |
| `a1.l` | output write position |
| `d0.b` | compressed bits |
| `d1.w` | bytes left; zero after resume means finished |
| `d2.w` | last match distance and current step |

For the ring decoder, save all of `d1.l` and `d2.l`; their upper words also
hold the ring limits.

To start, put the input in `a0` and the output start in `a1`, then call
`ST1_init`. Ring setup also takes the address just after the ring in `d3.l`.
Before every `ST1_resume`, put a fresh output limit in `d3.w`.

Both decoders may change `d3`, `d4`, `d5`, and `a2`. They leave `d6`, `d7`, and
`a3`–`a6` unchanged.

The linear `ST1_decompress` call decodes the whole file. Its output buffer must
keep all earlier output because matches may refer to it.

The ring call returns new bytes between the old and new `a1`. Use those bytes
before the next call. A call can return fewer bytes at the ring end or file end.
After draining the ring end, move `a1` back to the ring start. The source files
above contain complete calling examples.

## Example: streaming YM6

YM6 playback is one example of why the ring decoder is useful. A 50 Hz dump of
the YM2149's 14 sound registers uses about 41 KiB per minute, while the player
only needs the next value for each register.

For better compression, convert the YM6 file into one byte stream per register
before packing it:

```text
R0:  frame 0, frame 1, frame 2, ... → ZX1 stream 0 → small buffer 0
R1:  frame 0, frame 1, frame 2, ... → ZX1 stream 1 → small buffer 1
...
R13: frame 0, frame 1, frame 2, ... → ZX1 stream 13 → small buffer 13
```

Values from the same register tend to repeat, so they compress much better
together. Extra YM6 effect data can use extra streams when the player supports
it.

Start by decoding 16 values for every register. During playback, use one value
from every current block each video frame (VBL) and refill only one register
with its next 16 values:

```text
VBL  0: play value  0; refill R0
VBL  1: play value  1; refill R1
...
VBL 13: play value 13; refill R13
VBL 14: play value 14; free, or refill effect data
VBL 15: play value 15; free, or refill effect data
```

After VBL 15, start again at R0. Each decoder setup now produces 16 useful
values instead of one. The limit is a byte count, not a time limit, so measure
the slowest refill for the final tune.

With a 1024-byte ring and 16-byte calls, the current tests range from about 28
to 69 cycles per output byte, depending on the data. Using 70 cycles per byte is
a safe first estimate: one 16-byte refill costs about `16 × 70 = 1120` cycles.
A 16-stream player does one such refill per VBL, or about 1120 decompression
cycles per VBL. This number does not include saving the selected stream,
writing the YM registers, or loading packed data.

For this player, use rings of at least 32 bytes with sizes divisible by 16. A
128-byte ring holds 2.56 seconds of one register's past values at 50 Hz; 14
rings use 1792 bytes. Put equal-sized rings next to each other and moving to the
same place in the next ring becomes one add. With a fixed order, the player can
also share the write position. The decoder code may be placed directly in the
player loop so decoding, saving state, and moving to the next buffer happen
together.

ST1 only decompresses bytes. Your code must convert YM6, play the registers,
and provide the packed input.

## ST1 and MinYMiser

This YM example is directly inspired by
[MinYMiser](https://clarets.org/steve/projects/minymiser.html). Both split YM
data by register and keep only a small amount of old output.

MinYMiser uses a custom compressor made for YM music and one tight loop that
advances all 13 stored streams every VBL; it folds the mixer register into the
volume streams. ST1 can use the same 13-stream layout, or a simpler 14-stream
layout. It uses ZX1 because it compresses well and has a small decoder. Each
VBL it advances one stream by 16 values, then moves to the next stream.

MinYMiser has very small saved state and reads one packed input in order. ST1
uses separate ZX1 streams, spreads the work across VBLs, and reuses the same
decoder for other data. Both can group equal buffers and combine the decoder
with the player loop. Which is smaller or faster depends on the tune; a fair
answer needs both players tested with the same input and memory limits.

## Compatibility with ZX1

ST1, jx1, and nx1 use the normal ZX1 format. With no options, jx1 and nx1 make
the same bytes as the original C compressor. `-mN` changes which matches are
chosen and `-lN` limits their length; neither changes the file format.

[68k/test/emu/compat.py](68k/test/emu/compat.py) builds the original `zx1` and
`dzx1`, compares their output with jx1, and checks that each implementation can
read the other's files. The C# tests use the same Java and original-C examples.

## Tests and speed

The tests build Atari programs, check every output byte, and run with Hatari or
on an Atari ST:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

<!-- 68k-timings:begin -->
<!-- Generated by 68k/test/emu/cycle_model.py; inputs f07160960084 -->
With N=1024 and 16-byte calls on identical `-m1024` streams, the ring
decoder is on average about 12–13% slower than the resumable linear decoder
on the normal compressed test cases.

The full per-case cycle table, hardware measurements, stream-size cost,
and regeneration command are in [68k/test/README.md](68k/test/README.md).
<!-- 68k-timings:end -->

## Java and C# tools

Build and run the Java tools:

```sh
mvn package
java -ea -cp target/classes org.jx1.Jx1  [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
java -ea -cp target/classes org.jx1.Djx1 [-f] [-mN] input.zx1 [output]
```

`-mN` limits match distance, and `-lN` limits run length. Keep `-ea` when
running the classes directly because input checks use Java assertions.

The Java `Decompressor` can also stop after a chosen number of bytes:

```java
while (decompressor.resume()) {
    // do other work between chunks
}
```

The C# tools have the same options and API:

```sh
dotnet run --project csharp/src/Nx1.Cli -- [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
dotnet run --project csharp/src/Dnx1.Cli -- [-f] [-mN] input.zx1 [output]
```

See [csharp/README.md](csharp/README.md) for the .NET library and build steps.

## Names and files

The Atari ST was always the target. Java `jx1` and C# `nx1` are the tools and
readable reference versions used to test the handwritten `ST1.S` code. The
names follow a small demoscene joke: `ZX1` signs the ZX Spectrum version, `ST1`
signs the Atari ST version, and the host tools stay lowercase.

Assembly and Atari tests are in [`68k/`](68k/), Java is in `src/`, and C# is in
[`csharp/`](csharp/). Tagged builds are on
[GitHub Releases](https://github.com/odipar/ST1/releases).

## License and attribution

The license follows the original ZX1; see [LICENSE](LICENSE). The compressor is
BSD 3-Clause. The decompressors may be used freely, including commercially, if
their documentation says that ZX1 was used through ST1, jx1, or nx1.

The ZX1 format and algorithm are by Einar Saukas. The additions are © 2026
Robbert van Dalen. Claude (Anthropic's Claude Code) wrote the Java, ST1/68000,
tests, and optimization work. OpenAI Codex wrote the C# nx1 port. Both were
developed under Robbert's direction.
