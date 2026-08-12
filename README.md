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
* **68k target vs z80 target** — resumable 68000 decompressors ported from the Java
  `Decompressor` state machine, in nine variants (see the table below), all verified
  byte-identical against Java-compressed streams under cycle-measured emulation

## 68k variants

All variants share the same jump-table ABI (base+0 `jx1_init`, +4 `jx1_decompress`,
+8 `jx1_resume`) and produce identical output; they differ in size, state block, and
speed. The `opt*` variants assume no single op longer than 32K and chunk sizes 1..127
(undefined when violated). Speed figures are emulator-measured 68000 cycles. The full
optimization exploration behind the `opt_*` variants — 18 measured prototypes,
including insights and negative results — is documented in
[68k/OPTIMIZATIONS.md](68k/OPTIMIZATIONS.md).

| File | Bytes | State | Technique | Speed |
|---|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 284 | 22 | reference port, no assumptions; copy 30 cycles/byte, ~335-cycle fixed cost per resume call | baseline |
| [jx1_68000_opt.S](68k/jx1_68000_opt.S) | 278 | 19 | `dbf` copy loops (22 cycles/byte), word arithmetic, movem context tricks, all-short branches | 6–29% fewer instructions than base |
| [jx1_68000_opt2.S](68k/jx1_68000_opt2.S) | 282 | 15 | lastOffset and remaining packed into one `swap`-accessed register; d4 caller-preserved | 0.9–2.4% faster than opt (copy-dominated, chunk 16); ~1% slower parse-heavy |
| [jx1_68000_opt2_m.S](68k/jx1_68000_opt2_m.S) | 308 | 15 | `get_bit`/`take_budget` inlined as macros: no bsr/rts per bit read or per op | fastest: 27–29% over opt2 parse-heavy, 14–15% text, 4–7% copy-dominated |
| [jx1_68000_opt3.S](68k/jx1_68000_opt3.S) | 284 | 15 | z80/`unzx0` control flow: single refill in the gamma reader (ZX1 can only empty the bit queue on a continuation bit), bare `add.b` bit reads, one shared `resume_op`; no duplicated code; d4 clobbered | 1–28% over opt2, 1–7% behind opt2_m (chunks 16+) |
| [jx1_68000_opt4.S](68k/jx1_68000_opt4.S) | 418 | 15 | opt3 plus a two-tier copy engine: sizes <16 dispatch on `n&15` into a ladder of 16 rolled-out `move.b`s (computed `jmp (a4)`, address registers only); ≥16 uses an unrolled `move.l` pair loop with long/word/byte tail after an aligning head byte (needs equal parity, offset ≥ 4 for matches) — gate failures run ladder passes instead | vs opt3 at chunk 127: +33–44% on all copy-dominated data, +3% parse-heavy; at chunk 16: +5–9% copy-dominated, −2% parse-heavy |
| [jx1_68000_opt5.S](68k/jx1_68000_opt5.S) | 336 | 15 | opt4 reduced to the ladder alone: every copy dispatches on `n&15` into the rolled-out `move.b` ladder plus `n>>4` full passes — no alignment/overlap gates, uniform ~12.6 cycles/byte | 1–37% over opt3 everywhere; 2–8% over opt4 except large aligned copies at chunk 127, where opt4 stays 2–24% ahead |
| [jx1_68000_opt6.S](68k/jx1_68000_opt6.S) | 316 | 15 | opt5 with an 8-step ladder and a pc-relative dispatch (`jmp ladder_end(pc,d0.w)` with d0 = −2·(n&7), the file's one indexed mode): no base register, a3/a4 free again, clobbers back to d0–d5/a0–a2 | +0.4–0.6% over opt5 at chunk 16; 0.4–3.5% behind at chunk 127 (dbf every 8 bulk bytes instead of 16) |
| [jx1_68000_opt7.S](68k/jx1_68000_opt7.S) | 324 | 15 | opt6 with `get_gamma` peeled and rotated: the first continuation bit is read up front (length-1 values fall straight through) and the continue branch doubles as the loop jump — no unconditional `bra` per pair, no macros, no unrolling | +2.9–3.7% over opt6 on parse-heavy data, +1.1–2.1% text, +0.2–0.4% copy-dominated |

## 68k exploration variants

A measured optimization exploration beyond opt7 lives in
[68k/OPTIMIZATIONS.md](68k/OPTIMIZATIONS.md) (18 prototyped variants across six
themes, including the insights and negative results). The chunk-16-relevant
winners are checked in as `68k/jx1_68000_opt_<variant>.S` (wc3, threaded, smc2,
smc3, offlut, gammalut), and [68k/jx1_68000_opt_combo.S](68k/jx1_68000_opt_combo.S)
combines them: split literals/match bodies with a self-modified resume branch and
match-source `lea`, woven per-body gammas, a folded budget gate, and a 256-word
offset table — measured **+9.6–20.6% over opt7 at chunk 16** (up to +22.3% at
chunk 127), all corpora positive, at 918 bytes.
[68k/jx1_68000_opt_x16.S](68k/jx1_68000_opt_x16.S) tunes the combo further for
chunk 16 (32-step ladders, context shaves) and adds `jx1_resume_n`, a batched
resume that keeps all state in registers between chunks and runs the caller's
per-chunk work as a callback: **+27–30.6% over opt7 at chunk 16** with batches
of 4–8 chunks. The SMC variants require RAM code, a single active context, and
a plain 68000.

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
