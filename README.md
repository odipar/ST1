# jx1 — the Java version of ZX1

A Java port of [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by Einar Saukas, producing
byte-identical output to the original C implementation — checked on every run by
[68k/test/emu/compat.py](68k/test/emu/compat.py), which builds the C reference from
[c/zx1/src](c/zx1/src) and compares against it in
[both directions](#compatibility-with-zx1).

**Latest release: [v0.3](https://github.com/odipar/jx1/releases/tag/v0.3)**, with the
three assembled 68000 decompressors attached (290, 290 and 272 bytes). The sources
here are ahead of it — smaller, faster, and with a different calling convention — so
the sizes and the register contract below describe this tree, not that download.

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

jx1 is a port of ZX1, not a fork of the format: every jx1 stream is a ZX1
stream, and every ZX1 stream is a jx1 stream. With no options jx1 produces
byte-identical output to Einar Saukas' C compressor, and each side decompresses
what the other produces. [68k/test/emu/compat.py](68k/test/emu/compat.py)
checks all of that on every test run — including the 68000 decoders reading a
C-produced stream — against `zx1` and `dzx1` built from this repository's own
[c/zx1/src](c/zx1/src), so the reference is somebody else's implementation
rather than a stored fixture.

`-mN` and `-lN`, which the C compressor does not have, change *which parse is
chosen* and never the encoding, so what they emit is still ordinary ZX1.

Two warnings:

* **A stream compressed without `-l65535` may not be safe on a 68000.** The
  format allows an operation longer than 65535 bytes — 70000 identical bytes
  compress to a single 69999-byte match — and the 68000 decoders hold that
  length in a word. Such a stream decodes *short*, with no error. Java and the
  C tool decode it correctly, so nothing will warn you.
* **`-mN` is a promise about the decompressor, not a size knob.** It limits
  offsets to N so the stream can be decompressed through an N-byte ring
  buffer. Feeding a ring buffer a stream compressed without a matching `-mN`
  reads outside the buffer.

## The 68k decompressors

Three files, all ported from the Java `Decompressor` state machine, sharing
the same parser and the same copy engine, and **none of them has a context
block**: the whole state lives in six caller-held registers. They differ in where
the output goes and in what the caller has to promise:

| File | Code | Output | Entries |
|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 238 B | a linear buffer, which must hold the whole output — it *is* the match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 252 B | a caller-supplied ring of N bytes — memory bounded by N, not by the output | `jx1_init`, `jx1_resume` |
| [jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) | 234 B | the same ring, when N is a multiple of the budget | `jx1_init`, `jx1_resume` |

All three are verified byte-identical against Java-compressed streams under
cycle-measured emulation and on real 68000 hardware (Atari ST — see
[68k/test/](68k/test/)), and all three resume after at most one
budget of output.

[68k/jx1_68000.S](68k/jx1_68000.S) is the one to reach for unless you need
bounded memory:

* 238 bytes of position-independent code, and no context block at all
* one body — no macros, no tables, no self-modifying code; runs from ROM
* jump-table ABI: base+0 `jx1_init`, +4 `jx1_decompress`, +8 `jx1_resume`
* assumptions (undefined when violated): no single literal run or match
  longer than 65535 bytes; budgets 1..65535

### Trusted input only

All three decompressors validate **nothing** — not the stream, not the end of
the input, not the destination, not their parameters. That is what makes them
this small, and it means a malformed or hostile stream can read and write
arbitrary memory, while a budget of zero never advances an operation and
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
| `a0.l` | input position |
| `a1.l` | write pointer — where the output ends, after every call |
| `d0.b` | bit queue |
| `d1.w` | bytes remaining in the current operation |
| `d2.b` | operation state |
| `d3.w` | last offset |

The widths are what the decompressor touches — it never looks above `d0`'s low
byte or `d1`'s low word — so what you leave in the rest is your business.

`jx1_init` takes the stream in `a0` and the destination in `a1`, and seeds the
other four. Each `jx1_resume` emits at most `d4.w` bytes and returns `d5 = 0`
once the stream is fully processed. The budget is a **parameter, not state**,
so pass it every call — which also means a caller may vary it, or hand over a
whole 65535 at once:

```
        lea     stream,a0               ; compressed data
        lea     output,a1               ; destination
        bsr     jx1_init                ; seeds d0-d3; writes no memory
.loop:
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        ; ... your own work here; a1 = end of output so far ...
        tst.w   d5
        bne.s   .loop                   ; Java: while (resume()) { ... }
```

The only rule is the obvious one: whatever your own work does, it must
leave `a0`, `a1` and `d0`–`d3` as it found them, since those *are* the
decompressor.

| | registers |
|---|---|
| state, in and out | `a0.l` `a1.l` `d0.b` `d1.w` `d2.b` `d3.w` (rings also take `a2.l`/`a3.l`, read-only) |
| in | `d4.w`, this call's budget — **spent** by the call, so pass it again |
| out | `d5.l` — 0 done, 1 more |
| **clobbered** | **`d4.w` `d5.l` `d6.l` `a4.l`** |
| untouched | `d7` `a5` `a6`, and the stack beyond the return address |

The state sits at the bottom of both register files and the scratch above it,
which is the whole reason for this arrangement: `a0`/`a1` and `d0`–`d3` are
what a resume loop must leave alone, `a2`/`a3` are the ring bounds it already
holds, and everything from `d4`/`a4` upwards is the decompressor's to wreck.
`d5` and `d6` are working registers throughout — `d5` carries the segment
length and the copy-ladder index, `d6` the gamma value — so treat both as
gone across a call. `d5` is simply the last thing written to it.

`d3` holds the last offset alone rather than sharing a register with the
remaining count: reaching a packed offset costs a `swap` pair on every match
segment, which is 0.11 to 0.40 swaps per output byte across the benchmark
corpora.

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
buffer and budget, and
[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) is smaller and faster when
the budget divides the buffer (below). They share everything else — the same
parser, copy engine, entry work and interface — so read this section for
both.

Neither needs a callback or an extra return code: `jx1_resume` still returns
just 0 (done) and 1 (more), and neither has a context block either. They take
the same six state registers as the linear version plus the ring bounds,
read-only, in `a2.l`/`a3.l` — the caller holds those anyway, since it needs
them to drain. `d4.w` is the budget, and `d4.w`/`d5.l`/`d6.l`/`a4.l` come back
clobbered, exactly as for the linear version.

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
.loop:
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        ; consume [a6 .. a1)
        movea.l a1,a6
        cmpa.l  a3,a1                   ; buffer full?
        bne.s   .more
        movea.l a2,a6                   ; (ring_mod: also movea.l a2,a1)
.more:
        tst.w   d5
        bne.s   .loop
```

Decoding the same stream, the ring costs this much over the linear version:

| budget X | N = 1024 | N = 4096 | N = 32512 |
|---|---|---|---|
| 16 | +14.1…17.4% | +13.5…16.8% | +13.5…16.7% |
| 64 | +6.8…11.0% | +6.6…10.3% | +6.6…10.3% |
| 127 | +3.9…10.4% | +3.9…9.7% | +3.9…9.7% |

(ranges across the six benchmark corpora, 360 to 33012 bytes of output from
6- to 32589-byte streams; per-corpus sizes and figures are in
[68k/test/README.md](68k/test/README.md))

The ring's work is **per call and per match segment, never per byte** — one
clamp at entry, plus a source recompute and clamp for each match — so the
overhead is set by the budget that amortizes it and is essentially
independent of N (the three rows above move by less than 0.7 points across
1024-, 4096- and 32512-byte rings). Larger budgets are close to free; a
budget of 16 pays the entry clamp every 16 bytes. A small ring also costs
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
bytes, so use the write pointer rather than an assumed budget.

### When N is a multiple of X

[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) is the same decompressor
with that divisibility as a **requirement**, and spends it. `dst − start` is
then a multiple of X at every entry — it starts at 0, a call returning 1 wrote
exactly one budget, and a full buffer restarts at 0 — so the room is always
a whole number of budgets and never fewer than one. The budget therefore needs
no clamping at all: the entry drops the room arithmetic and keeps a single
compare that restarts a full buffer at its first byte.

**234 bytes, and faster than the general ring** — measured on
the Atari ST, against the +1.5% to +3.7% the cycle model predicts. Both files
carry the same entry work otherwise, so that difference is the price of the
general ring's room arithmetic and nothing else.

Every call also emits exactly X bytes and returns 1, except the final one,
which returns 0 with whatever is left — `output mod X` bytes, or a full budget
when X divides the output exactly. So a caller wanting fixed-size blocks gets
them for free — a property the ST harness checks on every call, across 42
configurations. Feeding it a budget that does not divide
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

The three decompressors above are what survived an optimization campaign;
seventeen other 68000 variants are kept in [retired/](retired/) rather than
deleted, because the measurements that rejected them are worth more than the
code. They include the straight port the project started from, the steps
between it and the current file, and several genuinely faster designs that
were turned down for what they demanded: self-modifying code, a 512-byte
table, or a limit of one active stream.

* [retired/68k/OPTIMIZATIONS.md](retired/68k/OPTIMIZATIONS.md) — the lab
  journal: eighteen prototypes across six themes, with the negative results
  written up as carefully as the wins
* [retired/68k/](retired/68k/) — the seventeen `.S` files themselves
* [retired/README.md](retired/README.md) — the README as it stood then, with
  the full variant tables

Two Java experiments are retired the same way, out of the Maven build and
documented in the same place: [retired/java/](retired/java/) holds a
decode-cost-aware parser and a chunk-aligned format variant, with their
tests.

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
| [v0.2](https://github.com/odipar/jx1/releases/tag/v0.2) | The ring buffer arrives on the 68000, in two forms and at no cost in context — `jx1_68000_ring.S` (300 B) for any buffer and chunk size, `jx1_68000_ring_mod.S` (288 B) when the chunk divides the buffer. The linear decompressor drops to 298 bytes, +32–36% over the straight port the project started from. A partial-register hazard in both ring decoders is fixed — the ABI declares `d0-d5` clobbered, so their *incoming* upper words are caller junk, and two clamps compared them long — and both harnesses now poison those registers before every call, with `run.sh` failing the command on any `BAD`. |
| [v0.1](https://github.com/odipar/jx1/releases/tag/v0.1) | First release: the Java port with `Jx1`/`Djx1`, custom buffer sizes, the incremental ring buffer and resumable decompression, plus the 68000 decompressor chosen from an 18-variant campaign and validated on real hardware timing. |

## License

Dual, following the original ZX1 (see [LICENSE](LICENSE)): the compressor is
BSD 3-Clause; the decompressors can be used freely within your own programs,
even commercially, as long as your documentation indicates you used ZX1/jx1.
The ZX1 format and algorithm are by Einar Saukas; the additions/differences
above are © 2026 Robbert van Dalen; the jx1 code and experiments were written
by Claude (Anthropic's Claude Code) under Robbert's direction.
