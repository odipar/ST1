# ST1 — streaming ZX1 decompression for the Atari ST

Keep assets packed. Spend the RAM on the demo.

ST1 is a small [ZX1](https://github.com/einar-saukas/ZX1) decompressor for the
plain 68000. ZX1 packs data very well while keeping the decoder small, which is
why it was chosen for ST1. ST1 can stop after a chosen number of output bytes
and continue later. Its ring decoders stream output through a small reusable
buffer. After your code consumes a returned block, it need not keep a second
copy; the decoder reuses that ring space later. The full output never has to fit
in memory. This makes ST1 useful for loaders, effects, music, and other work
that must share each video frame.

## 68000 decoders

ST1 provides three plain-68000 decoders. All read standard ZX1 data and keep
their state in five registers.

| File | Code | Use | Calls |
|---|---:|---|---|
| [ST1.S](68k/ST1.S) | 208 B | the whole output stays in one buffer | `ST1_init`, `ST1_decompress`, `ST1_resume` |
| [ST1_wrap.S](68k/ST1_wrap.S) | 222 B | caller-counted streaming when sizes are known | `ST1_init`, `ST1_resume` |
| [ST1_ring.S](68k/ST1_ring.S) | 272 B | output passes through a ring supplied by your code | `ST1_init`, `ST1_resume` |

The decoder documentation uses four size names: `I` is the packed input size,
`O` the decompressed output size, `N` the ring size, and `C` the output bytes
requested from one `ST1_resume` call.

Use [ST1.S](68k/ST1.S) when the whole output fits in memory. It can decode the
whole file with one call or stop and resume. The other two reuse a fixed
buffer—the ring. Use [ST1_wrap.S](68k/ST1_wrap.S) when the sizes and call pattern
are known, `C` divides `N`, and your caller can count destination wraps. Use
[ST1_ring.S](68k/ST1_ring.S) for variable call sizes or non-dividing shapes; it
stops each call at the ring end. Consume each returned block before its space
is reused for later output.

### Preparing files

The 68000 decoders use 16-bit word (`.w`) counters for each piece they decode,
so one piece cannot exceed 65535 output bytes. Use the Java `jx1` or C# `nx1`
packing tool with `-l65535` to enforce this limit. If the tool warns that it
cannot do so, do not use that output with ST1.

For a ring smaller than 32512 bytes, also use `-mN`, where `N` is the ring size
in bytes. This ensures that the decoder never needs data that has already left
the ring.

### Trusted input only

The decoders do not check the input, buffer, or arguments. Bad data can read or
write outside the buffers. Use trusted files made at build time, or validate
them before decoding.

- Ask `ST1_resume` for between 1 and 65535 bytes. Zero makes no progress.
- A ring may be from 1 to 65535 bytes.
- Keep the input, output, and saved registers valid until decoding ends.

### Calls and registers

- State: `a0.l`, `a1.l`, `d0.b`, `d1.w`, `d2.w`; for both ring decoders, save
  all of `d1.l` and `d2.l`.
- `ST1_init`: input in `a0`, output in `a1`; `ST1_ring.S` also takes the ring
  end in `d3.l`, while `ST1_wrap.S` takes `N` in `d3.w`.
- `ST1_resume`: `C` in `d3.w`; `d1.w = 0` means done for `ST1.S` and
  `ST1_ring.S`, but not for `ST1_wrap.S`.
- May change: `a2`, `d3`–`d5`. Unchanged: `d6`, `d7`, `a3`–`a6`.

### Counted wrapping

**Warning: `ST1_wrap.S` has no DONE state.** Make exactly `T = ceil(O/C)` calls
and never call it again; the final budget may be `O-(T-1)*C`. Choose `C` where
`N mod C = 0` and wrap `a1` after each `F = N/C` calls when more calls remain.
Keep `I` and `O` with the asset; use `-mN` when `N` is below 32512.

## Use case: streaming YM6

The [YM6 format](http://leonard.oxg.free.fr/ymformat.html) is a chiptune dump:
it stores the values written to the YM2149 sound chip for every video frame,
along with song details and optional effects. At 50 Hz, its 14 sound registers
use about 41 KiB per minute, although the player only needs the values it is
about to play. That makes it a good fit for ST1's streaming model: the player
handles the YM6 layout and sound registers, while ST1 supplies decompressed
bytes in small chunks.

Here is one possible player design. YM6 has an interleaved format option that
stores one vector for each of its 16 fields: every R0 value, then every R1 value,
through R15. Now let's pack the R0–R13 sound-register vectors as separate ZX1
streams. Values from the same register tend to repeat, so these streams compress
well. A player that supports YM6 effects must also handle their extra data.

Give each register stream its own saved decoder state and small ring, then fill
each ring with a group of 16 values, numbered 0–15. A vertical blank (VBL) is
one screen refresh. On each VBL, use the next numbered value from every register
and refill just one register with its next group:

```text
VBL  0: use value  0 from every register; refill R0
VBL  1: use value  1 from every register; refill R1
...
VBL 13: use value 13 from every register; refill R13
VBL 14: use value 14 from every register; no register refill
VBL 15: use value 15 from every register; no register refill
```

After VBL 15, start again at R0. This round-robin schedule spreads the work
evenly, and each decoder call prepares 16 VBLs for one register. Measure the
slowest refill with the final tune because the byte limit is not a time limit.

With 1024-byte rings and 16-byte calls, the tests report whole-stream averages
of about 28–69 cycles per output byte. Using 70 as a planning estimate gives
about `16 × 70 = 1120` decompression cycles for the single refill each VBL. This
excludes switching streams and writing the YM registers.

Use equal, adjacent rings in multiples of 16, with at least 32 bytes per ring so
the current and next groups both fit. YM data supplies a known `O` and uses a
fixed `C=16`, so `ST1_wrap.S` fits this design. The player can then move to the
next ring with one add and combine that update with the decoder code.

## ST1 and MinYMiser

This YM use case is directly inspired by
[MinYMiser](https://clarets.org/steve/projects/minymiser.html).

MinYMiser uses a custom YM compressor and advances its register streams together
every VBL. [YX6](yx6/README.md) is the MinYMiser-style player built with ST1: it
uses ZX1 and advances one 16-value group per VBL in round-robin order, and its
ST1 decoder can also serve other streamed data in the demo. Which player is
smaller or faster depends on the tune; a fair answer needs both tested with the
same input and memory limits.

## YX6: the YM player, built

[yx6/](yx6/README.md) implements that design: a Java packer that turns a YM6
dump into fourteen ZX1 streams, an 810-byte 68000 player that streams them
through ST1_wrap, and a script that links the two into a runnable `.PRG`.
Version 0.2 plays the fourteen standard YM2149 registers and loops; it plays no
effects.

```sh
mvn -q compile exec:exec@yx6 -Dargs="-f song.ym song.yx6"
yx6/mkprg.sh song.yx6                 # -> SONG.PRG
```

## Compatibility with ZX1

ST1, jx1, and nx1 use the standard ZX1 format. With no options, jx1 and nx1
produce the same bytes as the original ZX1 C compressor. They just get there
much faster: the same optimal parse is found without the C implementation's
per-candidate block allocations - measured about 2.5-3x quicker than the C
compressor built from this repo's own sources - and `-q` switches to an
event-driven parser that packs repetitive data at the same size hundreds of
times faster again, at the price of not being the C compressor's exact bytes.
The `-mN` and `-lN` options described above only change how data is packed,
not the file format.

[68k/test/emu/compat.py](68k/test/emu/compat.py) compares jx1 output byte for
byte with the original ZX1 C compressor, checks both sets of files with both
decompressors, and runs the ST1 decoders on C-produced streams. The C# tests use
the same reference examples.

## Tests and speed

The tests build Atari programs, check every output byte, and run with Hatari or
on an Atari ST:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
HATARI=/path/to/hatari TOS=/path/to/tos.img yx6/test/run.sh   # the YM player
```

<!-- 68k-timings:begin -->
<!-- Generated by 68k/test/emu/cycle_model.py; inputs 9391e28dfec3 -->
With N=1024 and C=16 on identical `-m1024` streams, counted wrap is
10.6% slower and the general ring 12.7% slower than
resumable linear on average across the normal compressed test cases.

The full per-case cycle table, hardware measurements, stream-size cost,
and regeneration command are in [68k/test/README.md](68k/test/README.md).
<!-- 68k-timings:end -->

## Java and C# tools

Build and run the Java tools:

```sh
mvn package
java -ea -cp target/classes org.jx1.Jx1  [-mN] [-lN] input [output.zx1]
java -ea -cp target/classes org.jx1.Djx1 [-mN] input.zx1 [output]
java -ea -cp target/classes org.yx6.Yx6  [-nN] [-cC] input.ym [output.yx6]
```

For `jx1`, `-mN` limits how far the packed data can look back; for `djx1`, it
sets the ring size. `-lN` limits the output bytes in one packed piece. Keep `-ea`
when running the classes directly because input checks use Java assertions.

The Java `Decompressor` can also stop after a chosen number of bytes:

```java
while (decompressor.resume()) {
    // do other work between chunks
}
```

The C# tools mirror the Java options and API:

```sh
dotnet run --project csharp/src/Nx1.Cli -- [-mN] [-lN] input [output.zx1]
dotnet run --project csharp/src/Dnx1.Cli -- [-mN] input.zx1 [output]
```

See [csharp/README.md](csharp/README.md) for the .NET library and build steps.

## Names and files

The Atari ST was always the target. Java `jx1` is the readable reference used by
the tests for the handwritten `ST1.S` code; C# `nx1` is an independent port of
the same tooling. The names follow a small demoscene joke: `ZX1` signs the ZX
Spectrum version, `ST1` signs the Atari ST version, and the host tools stay
lowercase.

Assembly and Atari tests are in [`68k/`](68k/), the YM player and its packer in
[`yx6/`](yx6/) and `src/main/java/org/yx6/`, Java is in `src/`, and C# is in
[`csharp/`](csharp/). Tagged builds are on
[GitHub Releases](https://github.com/odipar/ST1/releases).

## License and attribution

The license follows the original ZX1; see [LICENSE](LICENSE). The compressor is
BSD 3-Clause. The decompressors may be used freely, including commercially, if
your program's documentation says that ZX1 was used through ST1, jx1, or nx1.

The ZX1 format and algorithm are by Einar Saukas. The additions are © 2026
Robbert van Dalen. Claude (Anthropic's Claude Code) wrote the Java, the first
ST1/68000 decoders, tests, and optimization work. OpenAI Codex wrote the C# nx1
port and the counted-wrap decoder and tests. Both were developed under
Robbert's direction.

Special thanks to Sandor Drieënhuizen for his support, proofreading, and ideas.
