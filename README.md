# jx1 — the Java version of ZX1

A Java port of [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by Einar Saukas, producing
byte-identical output to the original C implementation — checked on every run by
[68k/test/emu/compat.py](68k/test/emu/compat.py), which builds the C reference from
[c/zx1/src](c/zx1/src) and compares against it in
[both directions](#compatibility-with-zx1).

**Latest release: [v0.3](https://github.com/odipar/jx1/releases/tag/v0.3)** — the three
assembled 68000 decompressors are attached to it (290, 290 and 272 bytes).

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

## Compatibility with ZX1

jx1 is a port, not a fork of the format: a jx1 stream is a ZX1 stream and vice
versa. [68k/test/emu/compat.py](68k/test/emu/compat.py) builds `zx1` and `dzx1`
from this repository's own copy of the C sources — so the reference is Einar
Saukas' implementation, freshly compiled, not a stored fixture — and asks four
questions:

| | check | scope |
|---|---|---|
| 1 | jx1's output equals the C compressor's, byte for byte | 11 corpora × default, `-b`, `-q` |
| 2 | jx1 decompresses what C compresses | 11 streams |
| 3 | C decompresses what jx1 compresses | 11 corpora × 6 option sets, including `-mN` and `-lN` |
| 4 | the **68000** decoders decode a C-produced stream | 44 decodes across all three |

The fourth is the one that cannot be faked. Everything else checks jx1 against
jx1, where a shared misunderstanding of the format would pass unnoticed; there
the reference is somebody else's code.

Question 3 covers the two options C does not have. `-mN` and `-lN` change
*which parse is chosen*, never the encoding, so what comes out is ordinary ZX1
— which is why `dzx1` reads all of it. The one place the two compressors
legitimately differ is `-l65535` on input with a very long match: C emits one
69999-byte match where jx1 emits two, so C's stream is smaller and jx1's is
safe on a 68000. Both are valid, and both decode to the same bytes.

## The 68k decompressors

Three files, all ported from the Java `Decompressor` state machine, sharing
the same parser and the same copy engine, and **none of them has a context
block**: the whole state lives in six caller-held registers. They differ in where
the output goes and in what the caller has to promise:

| File | Code | Output | Entries |
|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 238 B | a linear buffer, which must hold the whole output — it *is* the match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 252 B | a caller-supplied ring of N bytes — memory bounded by N, not by the output | `jx1_init`, `jx1_resume` |
| [jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) | 234 B | the same ring, when N is a multiple of the chunk size | `jx1_init`, `jx1_resume` |

All three are verified byte-identical against Java-compressed streams under
cycle-measured emulation and on real 68000 hardware (Atari ST — see
[68k/test/](68k/test/)), and all three resume after at most one chunk of
output.

### Why there is no context block

A resumable decompressor has to keep its parse state somewhere between calls.
The obvious place is a caller-supplied context block, and that is where this
one started: 16 bytes, loaded at entry and stored back at suspend. Every
field that left it made the decoder smaller *and* faster, so eventually all of
them did.

| step | context | linear | measured on an Atari ST |
|---|---|---|---|
| the write pointer becomes the caller's `a1` | 16 → 12 B | 290 B | +1.2…3.2% at chunk 16 |
| the rest of the state becomes registers | 12 → **none** | 242 B | **+7.6…17.2%** at chunk 16 |
| the last offset gets a register of its own | — | 238 B | +0.0…2.1% |

The middle row is the one that matters. A call had been opening with a
`movem`, a `move.w` and two `move.b`s, and closing with the same in reverse —
about **100 cycles of pure bookkeeping per call**, on a call that at chunk 16
produces only sixteen bytes. Holding the state in registers costs the caller
nothing it was not already doing: a drain loop touches `a1` anyway, and the
rest it simply leaves alone.

What it buys, beyond the cycles: nothing to allocate, nothing to align,
nothing to keep alive, and a second concurrent stream is a second set of
registers rather than a second block of memory.

**Decision (2026-08-13): [68k/jx1_68000.S](68k/jx1_68000.S) is the
project's 68000 decompressor** (formerly `jx1_68000_opt7.S`; renamed once
chosen). It came out of an 18-variant optimization campaign as the sweet
spot between speed, size, and readability:

* 238 bytes of position-independent code, and no context block at all
* one body — no macros, no tables, no self-modifying code; runs from ROM
* +32–36% faster than the straight reference port at chunk 16 (+42–52% at
  chunk 127) when it was chosen, and faster again since — measured under a
  cycle-accurate emulation model and confirmed on an Atari ST
* jump-table ABI: base+0 `jx1_init`, +4 `jx1_decompress`, +8 `jx1_resume`
* assumptions (undefined when violated): no single literal run or match
  longer than 65535 bytes; budgets 1..65535

### Trusted input only

All three decompressors validate **nothing** — not the stream, not the end of
the input, not the destination, not their parameters. That is what makes them
this small, and it means a malformed or hostile stream can read and write
arbitrary memory, while a chunk size of zero never advances an operation and
spins a caller's drain loop forever. They are built for assets you compressed
yourself at build time. For data you did not produce, validate the stream and
its decompressed length before calling in — the Java `Decompressor` runs its
checks under `-ea` — or decompress somewhere it cannot do harm.

One contract is easy to violate by accident: **no single operation may exceed
65535 bytes**, because the length lives in a word. A plain `jx1` stream can
exceed that — 70000 identical bytes compress to one 69999-byte match — and
such a stream decodes *short* on a 68000 with no error at all.

`jx1 -l65535` rules it out. It leaves the parse alone and splits an over-long
**match** into several at the same offset, costing two or three bytes per
65535. A **literal** run cannot be split: the format has no way to say "more
literals", since after a literal run a 0 bit means a match. So if one somehow
exceeded the limit the compressor would say so rather than fix it — but that
takes incompressible data on a scale where it does not arise: 500 KB of random
bytes produces a longest literal run of about 3300.

### Calling it

The decompressor is position-independent and has **no context block and no
global state**: the whole thing lives in five caller-held registers, and a
resume loop just leaves them alone between calls.

| register | role |
|---|---|
| `a0` | input position |
| `a1` | write pointer — where the output ends, after every call |
| `d0` | bit queue |
| `d1` | bytes remaining in the current operation |
| `d2` | operation state |
| `d3` | last offset |

`jx1_init` takes the stream in `a0` and the destination in `a1`, and seeds the
other four. Each `jx1_resume` emits at most `d4.w` bytes and returns `d5 = 0`
once the stream is fully processed. The budget is a **parameter, not state**,
so pass it every call — which also means a caller may vary it, or hand over a
whole 65535 at once:

```
        lea     stream,a0               ; compressed data
        lea     output,a1               ; destination
        bsr     jx1_init                ; seeds d0-d3; writes no memory
.chunk:
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        ; ... per-chunk work here; a1 = end of output so far ...
        tst.w   d0
        bne.s   .chunk                  ; Java: while (resume()) { ... }
```

The only rule is the obvious one: whatever the per-chunk work does, it must
leave `a0`, `a1` and `d0`–`d3` as it found them, since those *are* the
decompressor.

| | registers |
|---|---|
| state, in and out | `a0` `a1` `d0` `d1` `d2` `d3` (rings also take `a2`/`a3`, read-only) |
| in | `d4.w`, this call's budget — **spent** by the call, so pass it again |
| out | `d5` — 0 done, 1 more |
| **clobbered** | **`d4` `d5` `d6` `a4`** |
| untouched | `d7` `a5` `a6`, and the stack beyond the return address |

The state sits at the bottom of both register files and the scratch above it,
which is the whole reason for this arrangement: `a0`/`a1` and `d0`–`d3` are
what a resume loop must leave alone, `a2`/`a3` are the ring bounds it already
holds, and everything from `d4`/`a4` upwards is the decompressor's to wreck.
`d5` and `d6` are working registers throughout — `d5` carries the segment
length and the copy-ladder index, `d6` the gamma value — so treat both as
gone across a call. `d5` is simply the last thing written to it.

`d3` has the last offset to itself because it used to share `d1`'s high word,
and reaching it cost a `swap` pair on every match segment — 0.11 to 0.40
swaps per output byte on the benchmark corpora. Spending a register that
nothing else wanted bought **+1.2% to +1.5%** and four bytes.

`jx1_decompress` (a0 = stream, a1 = destination) is the one-shot convenience:
it runs the whole stream and returns with `a1` at the end of the output. It
passes itself a budget of 65535, so a 32 KB output is one pass instead of 252
— worth +4.2% to +16.3% over resuming at 127, for the same two bytes of code.

Polling a finished stream keeps returning 0, and `a1` is where the output
ends, on every call including the last. Matches are copied from the
destination itself — the output buffer is the window, so it must hold
everything decompressed so far. To decompress into **bounded memory**, use one
of the ring-buffer versions below.

### The ring-buffer versions

The Java `Decompressor` streams output through a caller-supplied ring buffer,
so memory use is bounded by the buffer rather than by the output. Two files
carry that to the 68000: [jx1_68000_ring.S](68k/jx1_68000_ring.S) takes any
buffer and chunk size, and
[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) is smaller and faster when
the chunk divides the buffer (below). They share everything else — the same
parser, copy engine, entry work and interface — so read this section for
both.

Neither needs a callback or an extra return code: `jx1_resume` still returns
just 0 (done) and 1 (more), and neither has a context block either. They take
the same six state registers as the linear version plus the ring bounds,
read-only, in `a2`/`a3` — the caller holds those anyway, since it needs them
to drain. `d4` is the budget, and `d4`/`d5`/`d6`/`a4` come back clobbered,
exactly as for the linear version.

`jx1_resume` (slot base+4 — there is no one-shot, since a bounded buffer has
to be drained) takes the ring bounds read-only in a2/a3 and the write pointer
in a1, and hands a1 back. The caller drains after every call and spots the
wrap itself: the write pointer never wraps *during* a call, so a full buffer
simply shows up as `a1 == a3`. `jx1_68000_ring.S` then wraps it for you on the
next call; `jx1_68000_ring_mod.S` does not, so wrap it in the branch you
already have.

```
        lea     stream,a0
        lea     ring,a1                 ; N bytes; no alignment requirement
        bsr     jx1_init                ; seeds d0-d3; writes no memory
        lea     ring,a2                 ; the state is all the caller's: bounds
        lea     ring+4096,a3            ; in a2/a3, write pointer in a1
        movea.l a2,a6                   ; a6 = first undrained byte
.chunk:
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        ; consume [a6 .. a1)
        movea.l a1,a6
        cmpa.l  a3,a1                   ; buffer full?
        bne.s   .more
        movea.l a2,a6                   ; (ring_mod: also movea.l a2,a1)
.more:
        tst.w   d0
        bne.s   .chunk
```

Decoding the same stream, the ring costs this much over the linear version:

| chunk X | N = 1024 | N = 4096 | N = 32512 |
|---|---|---|---|
| 16 | +14.1…17.4% | +13.5…16.8% | +13.5…16.7% |
| 64 | +6.8…11.0% | +6.6…10.3% | +6.6…10.3% |
| 127 | +3.9…10.4% | +3.9…9.7% | +3.9…9.7% |

(ranges across the six benchmark corpora, 360 to 33012 bytes of output from
6- to 32589-byte streams; per-corpus sizes and figures are in
[68k/test/README.md](68k/test/README.md))

The ring's work is **per call and per match segment, never per byte** — one
clamp at entry, plus a source recompute and clamp for each match — so the
overhead is set by the chunk size that amortizes it and is essentially
independent of N (the three rows above move by less than 0.7 points across
1024-, 4096- and 32512-byte rings). Larger chunks are close to free; a
16-byte chunk pays the entry clamp every 16 bytes. A small ring also costs
compression ratio, since offsets are capped at N.

A buffer of N bytes supports back-references up to exactly N, so compress with
`-mN`. N may be 1..65535; the format's offsets stop at 32512, so a larger ring
could never be referenced anyway. The entry clamps the call's budget to the room left in the buffer, so
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

**234 bytes, and faster than the general ring** — measured on
the Atari ST, against the +1.5% to +3.7% the cycle model predicts. Both files
carry the same entry work otherwise, so that difference is the price of the
general ring's room arithmetic and nothing else.

Every call also emits exactly X bytes and returns 1, except the final one,
which returns 0 with whatever is left — `output mod X` bytes, or a full chunk
when X divides the output exactly. So a caller wanting fixed-size blocks gets
them for free — a property the ST harness checks on every call, across 42
configurations. Feeding it a chunk that does not divide
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

## Releases

| | |
|---|---|
| [v0.3](https://github.com/odipar/jx1/releases/tag/v0.3) | An external audit's six findings, acted on. The headline one is a compatibility defect at the project boundary: the compressor could emit an operation longer than the 68000 decoders' 16-bit length, so 70000 identical bytes decoded to 4464 with no error. `jx1 -l65535` splits an over-long match instead, leaving the parse untouched. The real limit turned out to be 65535, twice what the sources assumed, now pinned by hand-authored boundary streams. All three decompressors shrink — 290, 290 and 272 bytes — and `jx1_decompress` gains +4.2–16.3% from a word-sized private budget. The rings hand the write pointer back to the caller, dropping their context to 12 bytes. The test suite is the other half: it assembles fresh every run, cannot report success while failing, checks its own documentation, and now verifies jx1 against the original C implementation built from `c/zx1/src` — including the 68000 decoders reading a C-produced stream. |
| [v0.2](https://github.com/odipar/jx1/releases/tag/v0.2) | The ring buffer arrives on the 68000, in two forms and at no cost in context — `jx1_68000_ring.S` (300 B) for any buffer and chunk size, `jx1_68000_ring_mod.S` (288 B) when the chunk divides the buffer. The linear decompressor drops to 298 bytes, +32–36% over the reference port. A partial-register hazard in both ring decoders is fixed — the ABI declares `d0-d5` clobbered, so their *incoming* upper words are caller junk, and two clamps compared them long — and both harnesses now poison those registers before every call, with `run.sh` failing the command on any `BAD`. |
| [v0.1](https://github.com/odipar/jx1/releases/tag/v0.1) | First release: the Java port with `Jx1`/`Djx1`, custom buffer sizes, the incremental ring buffer and resumable decompression, plus the 68000 decompressor chosen from an 18-variant campaign and validated on real hardware timing. |

## License

Dual, following the original ZX1 (see [LICENSE](LICENSE)): the compressor is
BSD 3-Clause; the decompressors can be used freely within your own programs,
even commercially, as long as your documentation indicates you used ZX1/jx1.
The ZX1 format and algorithm are by Einar Saukas; the additions/differences
above are © 2026 Robbert van Dalen; the jx1 code and experiments were written
by Claude (Anthropic's Claude Code) under Robbert's direction.
