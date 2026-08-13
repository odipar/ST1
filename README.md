# jx1 — the Java version of ZX1

A Java port of [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by Einar Saukas, producing
byte-identical output to the original C implementation (verified by extensive differential
testing against the C binaries, including custom offset limits).

Additions/differences to the original:

* **custom buffer/backreference sizes** — `jx1 -mN` limits match offsets to N bytes;
  `djx1 -mN` decompresses through an N-byte ring buffer. A buffer of size N supports
  offsets up to exactly N, so small targets can trade compression ratio for memory
  (e.g. `-m511` compresses for decompression in a 511-byte buffer)
* **incremental buffer** — `Decompressor` streams output through an externally supplied
  ring buffer passed to its constructor; each time the buffer fills, the abstract
  `flip(buffer, length)` method decides where the bytes go (the default implementation
  collects them in a growable in-memory buffer). No global state; instances are reusable
* **resumable decompression** — construction takes a chunk size X; `resume()` returns
  control to the caller after producing at most X output bytes, and returns `false` once
  the stream is fully processed: `while (d.resume()) { ... }` (named `resume` because
  `continue` is a reserved word in Java)
* **asserts instead of checks** — malformed-input validation uses Java `assert`, so run
  with `-ea` for descriptive errors; without it the checks vanish, like the z80/68k
  decompressors
* **68k target vs z80 target** — a resumable 68000 decompressor ported from the Java
  `Decompressor` state machine, in a linear and two ring-buffer forms, verified
  byte-identical against Java-compressed streams under cycle-measured emulation and
  on real 68000 hardware timing (Atari ST)

## The 68k decompressors

Three files, all ported from the Java `Decompressor` state machine, sharing
the same parser, the same copy engine and the same 16-byte context. They differ in where the output
goes, and in what the caller has to promise:

| File | Code | Context | Output | Entries |
|---|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 320 B | 16 B | a linear buffer, which must hold the whole output — it *is* the match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 338 B | 16 B | a caller-supplied ring of N bytes — memory bounded by N, not by the output | `jx1_init`, `jx1_resume` |
| [jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) | 326 B | 16 B | the same ring, when N is a multiple of the chunk size | `jx1_init`, `jx1_resume` |

All three are verified byte-identical against Java-compressed streams under
cycle-measured emulation and on real 68000 hardware (Atari ST — see
[68k/test/](68k/test/)), and all three resume after at most one chunk of
output.

**Decision (2026-08-13): [68k/jx1_68000.S](68k/jx1_68000.S) is the
project's 68000 decompressor** (formerly `jx1_68000_opt7.S`; renamed once
chosen). It came out of an 18-variant optimization campaign as the sweet
spot between speed, size, and readability:

* 320 bytes of position-independent code, 16-byte word-aligned context
* one body — no macros, no tables, no self-modifying code; runs from ROM,
  unlimited concurrent contexts
* +32–35% faster than the straight reference port at chunk 16 (+41–52% at
  chunk 127), measured under a cycle-accurate emulation model
* jump-table ABI: base+0 `jx1_init`, +4 `jx1_decompress`, +8 `jx1_resume`
* assumptions (undefined when violated): no single literal run or match
  longer than 32K, chunk sizes 1..127

### Calling it

The decompressor is position-independent and has no global state: everything
lives in a caller-supplied context block of 16 bytes, which
must be **word-aligned**. `jx1_init` takes the stream in `a0`, the destination
in `a1`, the chunk size in `d0.b` (1..127) and the context in `a5`; each
`jx1_resume` then emits at most one chunk and returns `d0 = 0` once the stream
is fully processed, leaving `a1` at the current end of output:

```
        lea     stream,a0               ; compressed data
        lea     output,a1               ; destination
        moveq   #16,d0                  ; chunk size X
        lea     context,a5              ; 16 bytes, word-aligned
        bsr     jx1_init
.chunk:
        bsr     jx1_resume              ; at most X bytes per call
        ; ... per-chunk work here; a1 = end of output so far ...
        tst.w   d0
        bne.s   .chunk                  ; Java: while (resume()) { ... }
```

`jx1_decompress` (a0 = stream, a1 = destination) is the one-shot convenience:
it runs the whole stream and returns with `a1` at the end of the output.

Both entries clobber `d0-d5/a0-a2` and leave `a5` untouched (`jx1_decompress`
uses but restores `a5`); `d6/d7` and `a3/a4/a6` are never touched. Matches are
copied from the destination itself — the output buffer is the window, so it
must hold everything decompressed so far. To decompress into **bounded
memory**, use one of the ring-buffer versions below.

### The ring-buffer versions

The Java `Decompressor` streams output through a caller-supplied ring buffer,
so memory use is bounded by the buffer rather than by the output. Two files
carry that to the 68000: [jx1_68000_ring.S](68k/jx1_68000_ring.S) takes any
buffer and chunk size, and
[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) is smaller and faster when
the chunk divides the buffer (below). They share everything else — the same
parser, copy engine, entry work and interface — so read this section for
both.

Neither needs a callback, an extra return code, or extra context:
`jx1_resume` still returns just 0 (done) and 1 (more), and the context is the
same 16-byte block as the linear version.

`jx1_init` is unchanged except that a1 is the ring buffer. `jx1_resume` (slot
base+4 — there is no one-shot, since a bounded buffer has to be drained) takes
the ring bounds as read-only parameters in a3/a4, and leaves the write pointer
in a1. The caller drains after every call and spots the wrap itself: the write
pointer never wraps *during* a call, so a full buffer simply shows up as
`a1 == a4`, and the next call restarts at a3.

```
        lea     stream,a0
        lea     ring,a1                 ; N bytes; no alignment requirement
        moveq   #16,d0                  ; chunk size X
        lea     context,a5              ; 16 bytes, word-aligned
        bsr     jx1_init
        lea     ring,a3                 ; ring bounds: parameters, not state
        lea     ring+4096,a4
        movea.l a3,a6                   ; a6 = first undrained byte
.chunk:
        bsr     jx1_resume
        ; consume [a6 .. a1)
        movea.l a1,a6
        cmpa.l  a4,a1                   ; buffer full? next call restarts at a3
        bne.s   .more
        movea.l a3,a6
.more:
        tst.w   d0
        bne.s   .chunk
```

Decoding the same stream, the ring costs this much over the linear version:

| chunk X | N = 1024 | N = 4096 | N = 65536 |
|---|---|---|---|
| 16 | +8.1…15.9% | +7.9…15.3% | +8.0…15.1% |
| 64 | +4.2…12.8% | +3.9…12.0% | +3.8…12.0% |
| 127 | +4.2…12.4% | +3.0…11.6% | +2.5…11.6% |

(ranges across the six benchmark corpora, 360 to 33012 bytes of output from
6- to 32589-byte streams; per-corpus sizes and figures are in
[68k/test/README.md](68k/test/README.md))

The ring's work is **per call and per match segment, never per byte** — one
clamp at entry, plus a source recompute and clamp for each match — so the
overhead is set by the chunk size that amortizes it and is essentially
independent of N (the three rows above move by less than 0.5 points across
1024-, 4096- and 65536-byte rings). Larger chunks are close to free; a
16-byte chunk pays the entry clamp every 16 bytes. A small ring also costs
compression ratio, since offsets are capped at N.

A buffer of N bytes supports back-references up to exactly N, so compress with
`-mN`. The entry clamps the call's budget to the room left in the buffer, so
the destination can never reach the buffer end *inside* a call — only exactly
as the budget runs out — which is why no copy needs a destination bounds test
and the buffer is wrapped once, at the next entry. A match source that runs
into the buffer end still splits the copy into segments, so the rolled-out
ladder itself never needs a bounds test.

A call that runs into the end of the buffer therefore produces fewer than X
bytes, so use the write pointer rather than an assumed chunk size.

### When N is a multiple of X

[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) is the same decompressor
with that divisibility as a **requirement**, and spends it. `dst − start` is
then a multiple of X at every entry — it starts at 0, a call returning 1 wrote
exactly one chunk, and a full buffer restarts at 0 — so the room is always a
whole number of chunks and never fewer than one. The budget therefore needs
no clamping at all: the entry drops the room arithmetic and keeps a single
compare that restarts a full buffer at its first byte.

**326 bytes, and 1.5–3.4% faster than the general ring** — measured at
+1.8–4.1% on the Atari ST. Both files carry the same entry work otherwise,
so that difference is the price of the general ring's room arithmetic and
nothing else.

Every call also emits exactly X bytes and returns 1, except the final one,
which returns 0 with the last `output mod X` bytes, so a caller wanting
fixed-size blocks gets them for free — a property the ST harness checks on
every call, across 42 configurations. Feeding it a chunk that does not divide
the buffer runs the destination past the end, so use `jx1_68000_ring.S` when
the caller cannot promise the ratio.

### Testing them

[68k/test/](68k/test/) holds two TOS programs that run the decompressors on a
real 68000 — under Hatari's cycle-exact Atari ST emulation, or on the machine
itself (`rmac -p` emits a plain `.PRG`). They verify every output byte and
measure decode time against a calibration loop of exactly known cycle count:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

The corpora and streams are generated by `gendata.py`, so only the sources are
checked in. Results, including what real hardware catches that emulation
cannot, are in [68k/test/README.md](68k/test/README.md).

## Retired exploration

The other seventeen variants — the reference port, the opt…opt6 progression,
six exploration winners, the combo, the x16 batched-resume speed champion
(+29–38% over opt7 at chunk 16, at the price of self-modifying code, a
512-byte table, and a single active context), and the chunk-aligned format
variant — are preserved in [retired/](retired/):

* [retired/README.md](retired/README.md) — the previous README with the
  complete variant tables, audited speed figures, and the
  baseline-vs-opt7-vs-x16 pick guide
* [retired/68k/OPTIMIZATIONS.md](retired/68k/OPTIMIZATIONS.md) — the measured
  lab journal: 18 prototypes across six themes, the insights, the negative
  results, and the final same-model audit of every claim
* [retired/68k/](retired/68k/) — all seventeen retired `.S` files

The Java classes behind retired experiments are retired too:
[retired/java/](retired/java/) holds `OptimizerDcaw` (the decode-cost-aware
parser), `CompressorChunked`/`DecompressorChunked` (the chunk-aligned
format), and their tests, out of the Maven build; their stories are in the
retired docs.

## Layout

| Class | Origin |
|---|---|
| `Block`, `Optimizer` | `zx1.h`, `memory.c` (obsoleted by GC), `optimize.c` |
| `Compressor` | `compress.c` |
| `Decompressor` | `dzx1.c`, restructured as a resumable state machine around the ring-buffer `flip` hook |
| `Jx1`, `Djx1` | the `zx1`/`dzx1` command-line tools renamed `jx1`/`djx1`, same flags plus `-mN` |

## Usage

```
mvn package
java -ea -cp target/classes org.jx1.Jx1  [-f] [-b] [-q] [-mN] input [output.zx1]
java -ea -cp target/classes org.jx1.Djx1 [-f] [-mN] input.zx1 [output]
```

or straight from Maven (a forked JVM with `-ea`, so assert-based validation
is on):

```
mvn -q compile exec:exec@jx1  -Dargs="[-f] [-b] [-q] [-mN] input [output.zx1]"
mvn -q compile exec:exec@djx1 -Dargs="[-f] [-mN] input.zx1 [output]"
```

See [c/zx1/src](c/zx1/src) for the original source code

## License

Dual, following the original ZX1 (see [LICENSE](LICENSE)): the compressor is
BSD 3-Clause; the decompressors can be used freely within your own programs,
even commercially, as long as your documentation indicates you used ZX1/jx1.
The ZX1 format and algorithm are by Einar Saukas; the additions/differences
above are © 2026 Robbert van Dalen; the jx1 code and experiments were written
by Claude (Anthropic's Claude Code) under Robbert's direction.
