# jx1 — the Java version of ZX1

A Java port of [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by Einar Saukas, producing
byte-identical output to the original C implementation (verified by extensive differential
testing against the C binaries, including custom offset limits).

Additions/differences to the original:

* **custom buffer/backreference sizes** — `zx1 -mN` limits match offsets to N bytes;
  `dzx1 -mN` decompresses through an N-byte ring buffer. A buffer of size N supports
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
  `Decompressor` state machine, verified byte-identical against Java-compressed streams
  under cycle-measured emulation

## The 68k decompressor

**Decision (2026-08-13): [68k/jx1_68000_opt7.S](68k/jx1_68000_opt7.S) is the
project's 68000 decompressor.** It came out of an 18-variant optimization
campaign as the sweet spot between speed, size, and readability:

* 324 bytes of position-independent code, 15-byte word-aligned context
* one body — no macros, no tables, no self-modifying code; runs from ROM,
  unlimited concurrent contexts
* +28–32% faster than the straight reference port at chunk 16 (+39–51% at
  chunk 127), measured under a cycle-accurate emulation model
* jump-table ABI: base+0 `jx1_init`, +4 `jx1_decompress`, +8 `jx1_resume`
* assumptions (undefined when violated): no single literal run or match
  longer than 32K, chunk sizes 1..127

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

The Java classes supporting retired experiments (`OptimizerDcaw`, the
decode-cost-aware parser; `CompressorChunked`/`DecompressorChunked`, the
chunk-aligned format) remain in the source tree; their stories are in the
retired docs.

## Layout

| Class | Origin |
|---|---|
| `Block`, `Optimizer` | `zx1.h`, `memory.c` (obsoleted by GC), `optimize.c` |
| `Compressor` | `compress.c` |
| `Decompressor` | `dzx1.c`, restructured as a resumable state machine around the ring-buffer `flip` hook |
| `Zx1`, `Dzx1` | the `zx1`/`dzx1` command-line tools, same flags plus `-mN` |

## Usage

```
mvn package
java -ea -cp target/classes org.jx1.Zx1  [-f] [-b] [-q] [-mN] input [output.zx1]
java -ea -cp target/classes org.jx1.Dzx1 [-f] [-mN] input.zx1 [output]
```

See [c/zx1/src](c/zx1/src) for the original source code
