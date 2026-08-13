# jx1 — the Java version of ZX1 (RETIRED README)

> **Retired 2026-08-13.** jx1 settled on `jx1_68000_opt7.S` as its 68000
> decompressor; the other seventeen variants and this README moved to
> `retired/`. This file is kept for its complete variant tables, measured
> speed figures, and the pick guide. opt7 itself still lives at
> [../68k/jx1_68000_opt7.S](../68k/jx1_68000_opt7.S); all other variant links
> below point at their retired copies. The current README is at
> [../README.md](../README.md).

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
  `Decompressor` state machine, in eighteen variants (see the tables below), all verified
  byte-identical against Java-compressed streams under cycle-measured emulation

## 68k variants

All nine variants below share the same jump-table ABI (base+0 `jx1_init`,
+4 `jx1_decompress`, +8 `jx1_resume`) and produce identical output; they differ in
size, state block, and speed (the exploration variants in the second table keep
this ABI too — `opt_x16` adds `jx1_resume_n` at base+12, and `chunked` reads its
own stream format). The `opt*` variants assume no single op longer than 32K and chunk sizes 1..127
(undefined when violated). Speed figures are emulator-measured 68000 cycles; every
figure in both tables comes from one re-measurement of all 18 variants under a
single corrected cycle model (see the audit section of
[68k/OPTIMIZATIONS.md](68k/OPTIMIZATIONS.md), which also documents the full
optimization exploration behind the `opt_*` variants — 18 measured prototypes,
including insights and negative results).

| File | Bytes | State | Technique | Speed |
|---|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 284 | 22 | reference port, no assumptions; copy 30 cycles/byte, ~335-cycle fixed cost per resume call | baseline |
| [jx1_68000_opt.S](68k/jx1_68000_opt.S) | 278 | 19 | `dbf` copy loops (22 cycles/byte), word arithmetic, movem context tricks, all-short branches | 6–30% fewer instructions than base |
| [jx1_68000_opt2.S](68k/jx1_68000_opt2.S) | 282 | 15 | lastOffset and remaining packed into one `swap`-accessed register; d4 caller-preserved | 0.9–2.4% faster than opt (copy-dominated, chunk 16); 0.5–1.2% slower parse-heavy |
| [jx1_68000_opt2_m.S](68k/jx1_68000_opt2_m.S) | 308 | 15 | `get_bit`/`take_budget` inlined as macros: no bsr/rts per bit read or per op | 26–29% over opt2 parse-heavy, 14–15% text, 5–7% copy-dominated (chunk 16; 1–4% at 127) |
| [jx1_68000_opt3.S](68k/jx1_68000_opt3.S) | 284 | 15 | z80/`unzx0` control flow: single refill in the gamma reader (ZX1 can only empty the bit queue on a continuation bit), bare `add.b` bit reads, one shared `resume_op`; no duplicated code; d4 clobbered | 0.4–28% over opt2, 1–7% behind opt2_m (chunks 16+) |
| [jx1_68000_opt4.S](68k/jx1_68000_opt4.S) | 418 | 15 | opt3 plus a two-tier copy engine: sizes <16 dispatch on `n&15` into a ladder of 16 rolled-out `move.b`s (computed `jmp (a4)`, address registers only); ≥16 uses an unrolled `move.l` pair loop with long/word/byte tail after an aligning head byte (needs equal parity, offset ≥ 4 for matches) — gate failures run ladder passes instead | vs opt3 at chunk 127: +33–44% on all copy-dominated data, +2% parse-heavy; at chunk 16: +5–8% copy-dominated, −3% parse-heavy |
| [jx1_68000_opt5.S](68k/jx1_68000_opt5.S) | 336 | 15 | opt4 reduced to the ladder alone: every copy dispatches on `n&15` into the rolled-out `move.b` ladder plus `n>>4` full passes — no alignment/overlap gates, uniform ~12.6 cycles/byte | 0.3–37% over opt3 everywhere; 2–8% over opt4 except large aligned copies at chunk 127, where opt4 stays 2–24% ahead |
| [jx1_68000_opt6.S](68k/jx1_68000_opt6.S) | 316 | 15 | opt5 with an 8-step ladder and a pc-relative dispatch (`jmp ladder_end(pc,d0.w)` with d0 = −2·(n&7), the file's one indexed mode): no base register, a3/a4 free again, clobbers back to d0–d5/a0–a2 | +0.4–0.6% over opt5 at chunk 16; 0.4–3.5% behind at chunk 127 (dbf every 8 bulk bytes instead of 16) |
| [jx1_68000_opt7.S](../68k/jx1_68000_opt7.S) | 324 | 15 | opt6 with `get_gamma` peeled and rotated: the first continuation bit is read up front (length-1 values fall straight through) and the continue branch doubles as the loop jump — no unconditional `bra` per pair, no macros, no unrolling | +2.9–3.7% over opt6 on parse-heavy data, +1.1–2.1% text, +0.0–0.4% copy-dominated |

## 68k exploration variants

A measured optimization exploration beyond opt7 lives in
[68k/OPTIMIZATIONS.md](68k/OPTIMIZATIONS.md) (18 prototyped variants across six
themes, including the insights and negative results). The chunk-16-relevant
winners, their combination, and two follow-ups are checked in alongside the
main line. Speed figures are vs opt7 at chunk 16 unless stated otherwise. The
SMC variants (smc2, smc3, combo, x16) require RAM code, a single active
context, and a plain 68000.

| File | Bytes | State | Technique | Speed |
|---|---|---|---|---|
| [jx1_68000_opt_wc3.S](68k/jx1_68000_opt_wc3.S) | 326 | 15 | opt7 re-plumbed: op state re-encoded so dispatch rides `tst`/`bmi` flags, context reordered for pure pre-decrement suspends, take_budget folded on the remaining ≥ 1 invariant, merged post-copy forks | +7.8–14.2% (word-soup +14.2%) |
| [jx1_68000_opt_threaded.S](68k/jx1_68000_opt_threaded.S) | 350 | 18 | threaded re-entry: `jmp`-dispatched per-state blocks (`r_lit`/`r_match`) with a gate-less take_budget for resumed ops; minimal-load context layout (entry 74 cycles, suspend 68) | +7.4–9.6% |
| [jx1_68000_opt_smc2.S](68k/jx1_68000_opt_smc2.S) | 350 | 15 | SMC: match source is a patched `lea <disp>(a1),a2` whose extension word holds −lastOffset (written once per new offset); offset decode negated end-to-end | +2.1–5.0% (rle +5.0%) |
| [jx1_68000_opt_smc3.S](68k/jx1_68000_opt_smc3.S) | 400 | 15 | SMC: split literals/match bodies — the op type lives in the program counter via a suspend-patched entry `bra.w`; all op-type tests and d4 maintenance vanish; includes smc2's patched lea | +7.8–12.6% (word-soup +12.6%) |
| [jx1_68000_opt_offlut.S](68k/jx1_68000_opt_offlut.S) | 836 | 15 | 256-word offset table: −offset = (L & 254) + G[H] — one indexed `add.w` replaces the two-byte path's shift/combine arithmetic | +0.0–3.6% (word-soup +3.6%) |
| [jx1_68000_opt_gammalut.S](68k/jx1_68000_opt_gammalut.S) | 874 | 15 | gamma decode via a 256-entry table on refill-aligned starts; occupancy-limited, pays only on parse-heavy data | −0.1–+1.7% |
| [jx1_68000_opt_combo.S](68k/jx1_68000_opt_combo.S) | 918 | 15 | the winners combined: split bodies + patched entry/lea, woven per-body gammas, folded budget gate, 256-word offset table | +10.2–20.3% (up to +21.7% at chunk 127) |
| [jx1_68000_opt_x16.S](68k/jx1_68000_opt_x16.S) | 1114 | 16 | the combo tuned for X = 16: 32-step ladders, context shaves, `jx1_resume_n` batched resume (state stays in registers between chunks, caller's work runs as a callback), full-chunk continuation fast path (boundary budget = chunk by construction, so spanning ops skip the clamp and jump at the ladder through init-patched constants) | plain +16.5–19.4%, k=4 +27.5–35.3%, k=8 +28.9–38.2% |
| [jx1_68000_chunked.S](68k/jx1_68000_chunked.S) | 1006 | 16 | chunk-aligned format (streams from `CompressorChunked`): no op crosses a chunk boundary, so no budget clamp and no mid-op state; boundary codes 0/11/100/101 | 6–18% behind opt_x16 at k=8 (57% behind on barely-compressible max-offset), ~20–26% ratio cost |

## Choosing: baseline vs opt7 vs opt_x16

The three variants worth a head-to-head. opt7 is the sweet spot when code
size and readability matter: +28–32% over the baseline in a tenth of x16's
footprint, one body, no macros, no tables, no self-modifying code, runs from
ROM. x16 buys the next +16–19% (plain) to +29–38% (batched) with a 512-byte
table, split SMC bodies, and a callback ABI — worth it when decode speed at
small chunks is the whole point. The baseline stays the no-assumptions
reference. At chunk 127 the gaps widen further (opt7 reaches +39–51% over
the baseline).

| | [jx1_68000.S](68k/jx1_68000.S) | [jx1_68000_opt7.S](../68k/jx1_68000_opt7.S) | [jx1_68000_opt_x16.S](68k/jx1_68000_opt_x16.S) |
|---|---|---|---|
| Code bytes | 284 | 324 | 1114 (602 code + 512 table) |
| State bytes | 22 | 15 | 16 |
| Speed vs baseline (chunk 16) | — | +28–32% | +40–45% plain, +52–56% batched k=8 |
| Speed vs opt7 (chunk 16) | — | — | +16.5–19.4% plain, +28.9–38.2% batched k=8 |
| rle-32k cycles/byte (chunk 16) | 49 | 35 | 29 plain, 22 batched k=8 |
| Assumptions | none | ops ≤ 32K, chunks 1..127 | same as opt7 |
| Runs from ROM | yes | yes | no (self-modifying) |
| Active contexts | unlimited | unlimited | one (patches are global state) |
| API | init / decompress / resume | same | same + batched `jx1_resume_n` |
| Style | straight port of the Java state machine | one body, no macros, no tables, no SMC | split SMC bodies, 256-word offset table, callback ABI |

`OptimizerDcaw` (decode-cost-aware) scores the optimal-parse DP with
`bits + λ·decode-cycles`, producing format-compatible streams tuned for decoder
speed. Measured finding: the bit-optimal parse is already nearly decode-optimal —
beyond λ≈24, each ~1% of decode speed costs ~2–2.6% of size. λ=0 is bit-exact
with `Optimizer`.

The chunk-aligned format variant (`CompressorChunked` / `DecompressorChunked`
in Java plus the 68k above) is a documented negative result: mid-op
continuation beats any per-chunk format overhead. It is kept for its
simplicity — strictly deterministic per-chunk decode work with no state
carried across chunks.

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

See [c/zx1/src](../c/zx1/src) for the original source code
