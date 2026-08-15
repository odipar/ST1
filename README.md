# jx1 — Java and C# versions of ZX1

jx1 ports [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by Einar Saukas to
Java and C#. It includes compatible command-line tools, resumable ring-buffer
decompressors, and two small 68000 decompressors.

The ports add:

* `jx1 -mN` limits encoded back-references; `djx1 -mN` selects an N-byte
  decode ring and requires every encoded offset to fit it.
* `-lN` limits operation lengths; use `-l65535` for the 68000 decoders.
* Java `Decompressor.resume()` and C# `Decompressor.Resume()` emit at most a
  caller-selected chunk per call.
* `Decompressor` writes through a caller-supplied ring buffer and `flip`/`Flip`
  hook.

## Compatibility with ZX1

The encoding is unchanged: every jx1 stream is a ZX1 stream and vice versa.
With no options, jx1 produces byte-identical output to the original C
compressor. `-mN` changes the parse and `-lN` splits emitted matches; neither
changes the format.

[68k/test/emu/compat.py](68k/test/emu/compat.py) builds `zx1` and `dzx1` from
[c/zx1/src](c/zx1/src), compares both compressors, cross-decompresses their
output, and checks the 68000 decoders on a C-produced stream.

The C# tests port every Java behavior test and pin the compressor to the same
original-C golden streams, including skipped, backwards, and quick modes.

## Java CLI

```sh
mvn package
java -ea -cp target/classes org.jx1.Jx1  [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
java -ea -cp target/classes org.jx1.Djx1 [-f] [-mN] input.zx1 [output]
```

Or run through Maven, which starts a forked JVM with assertions enabled:

```sh
mvn -q compile exec:exec@jx1  -Dargs="[-f] [-b] [-q] [-mN] [-lN] input [output.zx1]"
mvn -q compile exec:exec@djx1 -Dargs="[-f] [-mN] input.zx1 [output]"
```

Malformed-input validation uses Java `assert`, so use `-ea` when invoking the
classes directly.

## Java decompression API

`Decompressor` takes compressed input, an external ring buffer, and optionally
a chunk size X. Each `resume()` emits at most X bytes and returns `false` once
the stream is complete:

```java
while (decompressor.resume()) {
    // work between chunks
}
```

When the ring fills, the abstract `flip(buffer, length)` method decides where
its bytes go; the static `decompress` helpers collect them in memory. Instances
have no global state and can be reset and reused.

## C# port

The C# implementation targets .NET 10 and mirrors the Java API and command-line
options. From the repository root:

```sh
dotnet build csharp/Jx1.slnx -c Release
dotnet run --project csharp/src/Jx1.Cli -- [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
dotnet run --project csharp/src/Djx1.Cli -- [-f] [-mN] input.zx1 [output]
dotnet test csharp/Jx1.slnx -c Release
```

For in-memory decoding, call `Jx1.Decompressor.Decompress(compressed)`. For
bounded or resumable output, derive from `Decompressor`, implement `Flip`, and
call `Resume` until it returns `false`. See [csharp/README.md](csharp/README.md)
for compression, publishing, and project-layout details.

## The 68k decompressors

Both files are position-independent, ROM-safe, and keep their entire
state in registers:

| File | Code | Output | Entries |
|---|---:|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 208 B | linear buffer containing the whole output and match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 266 B | arbitrary caller-supplied ring of N bytes | `jx1_init`, `jx1_resume` |

Entries are four-byte jump slots in table order. Use the linear decoder unless
output must pass through bounded memory; the ring decoder has no one-shot entry
because the caller must drain it.

### Trusted input only

The 68000 decoders validate nothing: not the stream, input end, destination,
or parameters. Malformed input can read or write arbitrary memory. They are
for trusted assets produced at build time; otherwise validate the stream and
decompressed length first or decode it in an isolated environment.

Their required contracts are:

* Each literal run or match is at most 65535 bytes. Compress with
  `jx1 -l65535`; over-long matches are split. An over-long literal run is
  reported but cannot be split, so that output is not 68000-safe.
* Every resume budget is in 1..65535. A zero budget makes no progress and can
  spin a drain loop forever.
* The ring size is 1..65535 and no stream offset exceeds it. For N below
  32512, compress with the matching `-mN`; rings of
  at least 32512 bytes cover the format's full offset range.
* Input, output, and the five state registers remain valid for the full decode.

### Calling convention

There is no context block. Preserve these five state registers between calls;
after draining a full ring, `a1` may be changed from the end back to the start:

| Register | Role |
|---|---|
| `a0.l` | input position |
| `a1.l` | write pointer; end of output produced so far |
| `d0.b` | bit queue |
| `d1.w` | bytes remaining; zero on return from `jx1_resume` means done |
| `d2.w` | signed offset/state: `+lastOffset` in LITERALS, `-lastOffset` in MATCH |

With `d1.w = 0`, `d2.w = -1` means START and zero means DONE. After
initialization, the linear resume entry preserves the unused high parts of
`d0`, `d1`, and `d2`. The ring instead keeps
`-start.low` in `d1.high` and `end.low` in `d2.high`, so its full `d1.l` and
`d2.l` are state.

Initialize with the stream in `a0` and destination in `a1`. Ring initialization
additionally takes its one-past-end pointer in `d3.l`. Thereafter, every
`jx1_resume` takes a fresh budget in `d3.w`; the call spends it rather than
refilling it.

Both clobber `d3.w`, `d4.l`, `d5.l`, and `a2.l`. They preserve `d6`,
`d7`, `a3`–`a6`, and the stack beyond the return address.

Linear example:

```
        lea     stream,a0
        lea     output,a1
        bsr     jx1_init
.loop:
        moveq   #16,d3
        bsr     jx1_resume
        ; consume or inspect output ending at a1
        tst.w   d1
        bne.s   .loop
```

`jx1_decompress` is the linear one-shot convenience. It takes the stream in
`a0`, destination in `a1`, and returns with `a1` at the output end. The linear
destination must hold everything decompressed so far because it is also the
match window. Polling a completed stream remains harmless and leaves
`d1.w = 0`.

### General ring

[jx1_68000_ring.S](68k/jx1_68000_ring.S) accepts any alignment, N in
1..65535, and a nonzero word budget that may vary between calls. Initialization
packs the ring metadata, so no persistent bound register is needed.

```
        lea     stream,a0
        lea     ring,a3                 ; caller-held start
        lea     ring+4096,a4            ; caller-held end
        movea.l a3,a1
        move.l  a4,d3                   ; init-only end parameter
        bsr     jx1_init
.loop:
        move.l  a1,-(sp)                ; span start
        moveq   #16,d3
        bsr     jx1_resume
        movea.l (sp)+,a2
        ; consume [a2 .. a1)
        cmpa.l  a4,a1
        bne.s   .more
        movea.l a3,a1                   ; drained: wrap before next call
.more:
        tst.w   d1
        bne.s   .loop
```

The decoder may instead receive `a1` left at the end and wrap it on the next
entry. Explicit wrapping is safer for callers that save each produced span's
start. A boundary call can be shorter than its requested budget, so use the
saved and returned pointers rather than assuming X bytes were emitted.

Destination room and `position = destination - start` are computed modulo
65536 from the packed low words. Because N is at most 65535, both values are
exact even when the ring crosses a 64-K boundary. A borrow from
`position - offset` detects a wrapped match source; the rare wrap path derives
zero-extended `N = end.low - start.low` from the same metadata.

An N-byte ring supports offsets through `min(N, 32512)`. For N below 32512,
compress with `-mN`; larger rings already cover the format's full range. The
decoder clamps once at call entry and splits only a match whose source reaches
the ring end, so bounds work is per call or match segment, not per byte.

### Testing

The hardware suite assembles fresh TOS programs, verifies every output byte,
and runs under cycle-exact Hatari or on an Atari ST:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

<!-- 68k-timings:begin -->
<!-- Generated by 68k/test/emu/cycle_model.py; inputs 62a6a2909a38 -->
Fair N=1024, X=16 resume comparison on identical `-m1024` streams.
Linear means `jx1_resume` at X=16, not the one-shot entry. Values
are ideal plain-MC68000 cycles for the decoder plus its required
resume-loop control flow; the ring cell shows its cost versus linear.

| corpus | linear | general ring |
|---|---:|---:|
| text | 11,412 | 12,780 (+12.0%) |
| wordsoup | 177,762 | 201,586 (+13.4%) |
| farmatch | 75,798 | 85,164 (+12.4%) |
| period129 | 28,058 | 31,446 (+12.1%) |
| allsame | 26,544 | 29,912 (+12.7%) |
| rle32k | 820,984 | 934,374 (+13.8%) |
| maxoffset | 870,344 | 918,610 (+5.5%) |

The matching hardware measurements, stream-size cost, and regeneration
command are in [68k/test/README.md](68k/test/README.md).
<!-- 68k-timings:end -->

## Layout

| Class | Origin |
|---|---|
| `Block`, `Optimizer` | `zx1.h`, `memory.c`, `optimize.c` |
| `Compressor` | `compress.c` |
| `Decompressor` | `dzx1.c`, restructured around resumable ring output |
| `Jx1` | the `zx1` tool plus `-mN` and `-lN` |
| `Djx1` | the `dzx1` tool plus `-mN` |

The Java sources are under `src/`; equivalent .NET library, CLI, and test
projects are under [`csharp/`](csharp/).

Tagged versions are available from [GitHub Releases](https://github.com/odipar/jx1/releases).

## License

Dual, following the original ZX1 (see [LICENSE](LICENSE)): the compressor is
BSD 3-Clause; the decompressors may be used freely, including commercially,
when their documentation says ZX1/jx1 was used. The ZX1 format and algorithm
are by Einar Saukas. The additions are © 2026 Robbert van Dalen. The Java,
68000, test, and optimization work was written by Claude (Anthropic's Claude
Code); the C# port was written by OpenAI Codex. Both were developed under
Robbert's direction.
