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
* **68k target vs z80 target** — [68k/jx1_68000.S](68k/jx1_68000.S) is a size-optimized
  (284 bytes), resumable 68000 decompressor with a 22-byte state block, ported from the
  Java `Decompressor` state machine and verified against Java-compressed streams under
  emulation. [68k/jx1_68000_opt.S](68k/jx1_68000_opt.S) is the performance-optimized
  variant (278 bytes, 19-byte state block): dbf copy loops (22 vs 30 cycles/byte), word
  arithmetic, movem context tricks and all-short branches give 6–29% fewer instructions
  than the base version (16–18% at chunk 16, ~29% at chunk 127 on copy-dominated data);
  it assumes ops no longer than 32K and chunk sizes 1..127.
  [68k/jx1_68000_opt2.S](68k/jx1_68000_opt2.S) additionally packs lastOffset and the
  remaining count into one register (swap-accessed), shrinking the state block to
  15 bytes, preserving d4, and saving another 0.9–2.4% of cycles on copy-dominated
  data at chunk 16 (~1% slower on parse-heavy data).
  [68k/jx1_68000_opt2_m.S](68k/jx1_68000_opt2_m.S) (308 bytes) further inlines
  `get_bit` and `take_budget` as macros, removing 34 cycles of bsr/rts overhead per
  bit read and per operation: 27–29% fewer cycles on parse-heavy data, 14–15% on
  text, 4–7% on copy-dominated data vs opt2.
  [68k/jx1_68000_opt3.S](68k/jx1_68000_opt3.S) (284 bytes) instead restructures the
  control flow like the z80 `dzx1_standard.asm` and `unzx0_68000.S`: the only bit-queue
  refill lives in the gamma reader (a ZX1 stream can only run the queue empty on a
  continuation bit), transition and data bits are bare `add.b`, and one shared
  `resume_op` body holds the single `take_budget` — no macros, no duplicated code,
  1–28% faster than opt2 and 1–7% behind opt2_m at chunks 16+ (tiny chunks pay the
  shared-body tax: down to ~2% slower than opt2 on barely-compressible data)

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
