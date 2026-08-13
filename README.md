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
  `Decompressor` state machine, in a linear and a ring-buffer variant, verified
  byte-identical against Java-compressed streams under cycle-measured emulation and
  on real 68000 hardware timing (Atari ST)

## The 68k decompressor

**Decision (2026-08-13): [68k/jx1_68000.S](68k/jx1_68000.S) is the
project's 68000 decompressor** (formerly `jx1_68000_opt7.S`; renamed once
chosen). It came out of an 18-variant optimization campaign as the sweet
spot between speed, size, and readability:

* 324 bytes of position-independent code, 15-byte word-aligned context
* one body — no macros, no tables, no self-modifying code; runs from ROM,
  unlimited concurrent contexts
* +28–32% faster than the straight reference port at chunk 16 (+39–51% at
  chunk 127), measured under a cycle-accurate emulation model
* jump-table ABI: base+0 `jx1_init`, +4 `jx1_decompress`, +8 `jx1_resume`
* assumptions (undefined when violated): no single literal run or match
  longer than 32K, chunk sizes 1..127
* validated on real 68000 hardware timing, not just emulation — see
  [68k/test/](68k/test/)

### Calling it

The decompressor is position-independent and has no global state: everything
lives in a caller-supplied context block of 15 bytes (16 with padding), which
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
memory**, use the ring-buffer variants below.

## Ring-buffer variant

The Java `Decompressor` streams output through a caller-supplied ring buffer,
so memory use is bounded by the buffer rather than by the output. This is that
same feature on the 68000, and it carries it without a callback: the
buffer-full event ("flip") is reported in `jx1_resume`'s return value.

[jx1_68000_ring.S](68k/jx1_68000_ring.S) is 350 bytes with a 23-byte context,
takes any buffer size N and any chunk size 1..127, and costs 10–22% over the
linear decompressor — the price of bounded memory.

`jx1_init` takes the ring in a1 and its size N in d1.l; `jx1_resume` (slot
base+4 — there is no one-shot, since a bounded buffer has to be drained)
returns:

* **0** — done. The bytes written since your last drain are `[last drain, a1)`
* **1** — more output, chunk budget spent
* **2** — more output, **and the buffer wrapped**: everything up to the end of
  the buffer is valid and must be consumed now, because the next call starts
  writing at the buffer's first byte again (Java: `flip(buffer, length)`)

```
        lea     stream,a0
        lea     ring,a1                 ; N bytes; no alignment requirement
        moveq   #16,d0                  ; chunk size X
        move.l  #4096,d1                ; ring size N
        lea     context,a5              ; 24 bytes, word-aligned
        bsr     jx1_init
.chunk:
        bsr     jx1_resume
        ; consume [drained, a1) — or [drained, ring+N) when d0 = 2
        tst.w   d0
        bne.s   .chunk
```

A buffer of N bytes supports back-references up to exactly N, so compress with
`-mN`. Rather than testing for a wrap per byte, each copy pass takes
`n = min(remaining, budget, end−dst, end−src)` and runs the same rolled-out
ladder as the linear version, wrapping the pointers between segments: a ring
costs a clamp per segment, not a test per byte.

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
