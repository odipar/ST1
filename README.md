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
block**: the whole state lives in five caller-held registers. They differ in
where the output goes and in what the caller has to promise:

| File | Code | Output | Entries |
|---|---|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 232 B | a linear buffer, which must hold the whole output — it *is* the match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 258 B | an arbitrarily placed caller-supplied ring of N bytes — memory bounded by N, not by the output | `jx1_init`, `jx1_resume` |
| [jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) | 232 B | a compile-time power-of-two ring, aligned to N, when N is a multiple of one fixed budget X | `jx1_init`, `jx1_resume` |

All three are verified byte-identical against Java-compressed streams under
cycle-measured emulation and on real 68000 hardware (Atari ST — see
[68k/test/](68k/test/)), and all three resume after at most one
budget of output.

[68k/jx1_68000.S](68k/jx1_68000.S) is the one to reach for unless you need
bounded memory:

* 232 bytes of position-independent code, and no context block at all
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
| `d3.w` | signed last offset: negative in LITERALS, positive in MATCH; with `d1.w = 0`, `+1` is START and `0` is DONE |

The linear and `ring_mod` decoders never look above `d0`'s low byte or
`d1`/`d3`'s low words, so after initialization the rest is your business. The
general ring is the one exception: `jx1_init` packs N into `d1`'s high word,
which must then survive along with the remaining count in its low word.

For the linear and `ring_mod` decoders, `jx1_init` takes the stream in `a0`
and the destination in `a1`, and seeds the other three registers. The general
ring also takes its one-past-end pointer in `d2`; initialization derives and
packs N from `d2-a1`. Each `jx1_resume` emits at most `d4.w` bytes and leaves
`d1.w = 0` once the stream is fully processed, nonzero while more remains. The
budget is a **parameter, not state**, so pass it every call. Linear and
general-ring callers may vary it, or hand over a whole 65535 at once;
`ring_mod` is the exception and requires the same fixed budget X on every
call:

```
        lea     stream,a0               ; compressed data
        lea     output,a1               ; destination
        bsr     jx1_init                ; seeds d0/d1/d3; writes no memory
.loop:
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        ; ... your own work here; a1 = end of output so far ...
        tst.w   d1
        bne.s   .loop                   ; Java: while (resume()) { ... }
```

The only rule is the obvious one: whatever your own work does, it must leave
`a0`, `a1`, `d0`, `d1`, and `d3` as it found them, since those *are* the
decompressor. The general ring also requires its preserved `d2` end bound to
survive between calls.

`d4.w` is the input budget in every case and is **spent** by the call. The
remaining register contract differs deliberately by output strategy:

| decoder | extra input or state | **clobbered** | untouched |
|---|---|---|---|
| linear | none | **`d4.w` `d5.l` `d6.l` `a4.l`** | `d2` `d7` `a2` `a3` `a5` `a6` |
| general ring | `d2.l` = end, read-only; `d1.high` = N after init | **`d4.w` `d5.l` `d6.l` `a2.l`** | `d7` `a3` `a4` `a5` `a6` |
| `ring_mod` | assembly-time `RING_SIZE` | **`d2.l` `d4.w` `d5.l` `d6.l`** | `d7` `a2` `a3` `a4` `a5` `a6` |

All three leave the stack beyond the return address untouched. The common
state remains in `a0`/`a1` and `d0`/`d1`/`d3`; only the general ring extends
it with the packed size and preserved end pointer. Its copy source is
transient `a2`. `ring_mod` instead borrows `a0` as the copy source during a
match and parks the compressed-input pointer in `d2`, leaving `a2` through
`a4` completely untouched.

`d5` and `d6` are working registers throughout — `d5` carries the segment
length and the copy-ladder index, `d6` the gamma value — so treat both as
gone across a call. The remaining count already in `d1` doubles as the result.

`d3` holds the last offset and operation state together: its magnitude is the
offset, and its sign distinguishes LITERALS from MATCH at no extra cost. It
still does not share a register with the remaining count: reaching a packed
offset costs a `swap` pair on every match segment, which is 0.11 to 0.40 swaps
per output byte across the benchmark corpora.

`jx1_decompress` (a0 = stream, a1 = destination) is the one-shot convenience:
it runs the whole stream and returns with `a1` at the end of the output. It
passes itself a budget of 65535, so a 32 KB output is one pass instead of 252
— worth +4.2% to +16.3% over resuming at 127, for the same two bytes of code.

Polling a finished stream keeps leaving `d1.w = 0`, and `a1` is where the
output ends, on every call including the last. Matches are copied from the
destination itself — the output buffer is the window, so it must hold
everything decompressed so far. To decompress into **bounded memory**, use one
of the ring-buffer versions below.

### The ring-buffer versions

The Java `Decompressor` streams output through a caller-supplied ring buffer,
so memory use is bounded by the buffer rather than by the output. Two files
carry that to the 68000: [jx1_68000_ring.S](68k/jx1_68000_ring.S) takes any
buffer and budget, and
[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) trades generality for fewer
registers when a fixed budget divides a power-of-two, size-aligned buffer.
They share the parser and copy ladder, but deliberately have different ring
ABIs.

Neither needs a callback or a separate return register: `d1.w` is zero when
done and nonzero when more remains, and neither has a context block. Their
`jx1_resume` is jump-table slot base+4; there is no one-shot entry because a
bounded buffer has to be drained.

The general ring accepts any placement, any N from 1 through 65535, and any
nonzero word budget. It represents the ring with one preserved value instead
of two address registers: `d2.l` is the one-past-end pointer, while
`jx1_init` derives N from `d2-a1` and packs it into `d1.high`. The low word of
`d1` remains the operation count and return value. `a2` is then free to be the
transient copy source; `a3` and `a4` are untouched.

```
        lea     stream,a0
        lea     ring,a3                 ; optional caller-held start; preserved
        movea.l a3,a1                   ; N bytes; no alignment requirement
        move.l  #ring+4096,d2            ; sole decoder bound: one past the end
        bsr     jx1_init                ; also packs N into d1.high
.loop:
        move.l  a1,-(sp)                ; first output byte for this call
        moveq   #16,d4                  ; at most 16 bytes from this call
        bsr     jx1_resume
        movea.l (sp)+,a2                ; a2 is already caller-clobbered
        ; consume [a2 .. a1)
        cmpa.l  d2,a1                   ; buffer full?
        bne.s   .more
        movea.l a3,a1                   ; wrap explicitly before saving a1
.more:
        tst.w   d1
        bne.s   .loop
```

The decoder also accepts `a1 == d2` and wraps it itself at the next entry by
subtracting the packed N. The explicit wrap above is useful because a caller
that saves the beginning of every produced span must normalize `a1` before
saving it again. With arbitrary N/X, a boundary call may be shorter than its
budget, so the saved pointer—not an assumed X—is the reliable span start.

The match path needs a source bound only when `dst-offset` underflows the
ring. If it does not underflow, the source lies behind the already-clamped
destination and therefore cannot reach the end first. If it does, the
unsigned borrow gives the exact room of the wrapped source. This makes the
common nonwrapping source setup 12 cycles cheaper than the former two-bound
form while reducing the persistent bounds from `a2/a3` to `d2` alone. The
258-byte result is 12 bytes larger because reconstructing a full 1..65535 N
without relying on signed address arithmetic takes a few extra instructions.

The ring's work is still **per call and per match segment, never per byte**:
one destination clamp at entry, and a source recompute only for matches.
Larger budgets amortize the entry clamp; a smaller ring may reduce the
compression ratio because offsets are capped at N. Per-corpus timings remain
in [68k/test/README.md](68k/test/README.md).

A buffer of N bytes supports back-references up to exactly N, so compress with
`-mN`. N may be 1..65535; the format's offsets stop at 32512, so a larger ring
could never be referenced anyway. The entry clamps the call's budget to the
room left in the buffer, so the destination can never reach the buffer end
*inside* a call—only exactly as the budget runs out. A match source that runs
into the buffer end splits the copy into segments, so the rolled-out ladder
itself needs no per-byte bounds test.

A call that runs into the end of the buffer therefore produces fewer than X
bytes, so use the write pointer rather than an assumed budget.

### The power-of-two fixed-budget specialization

[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) assembles for one
`RING_SIZE`, which must be a power of two from 1 through 32768. The buffer
base must be aligned to that size, the same fixed budget X must be used on
every call, and X must divide `RING_SIZE`. Those promises remove both ring
bounds from the decoder: the destination position is simply
`a1 & (RING_SIZE-1)`, and the carry from `position-offset` says whether the
match source wrapped.

The copy uses only two address registers. Literals consume input directly
through `a0`; for a match, the compressed-input pointer moves temporarily to
`d2` and `a0` becomes the source alongside destination `a1`. Thus `a2`, `a3`
and `a4` are all untouched. Nine registers are touched in total, down from
eleven in the runtime two-bound implementation, for a 232-byte decoder.

Assemble the source with `RING_SIZE` defined, place the ring at a matching
alignment, and keep its base in any preserved register if the drain loop
needs it:

```
        ; assemble with RING_SIZE=4096; ring is 4096-byte aligned
        lea     stream,a0
        lea     ring,a2                 ; caller-owned base; a2 is preserved
        movea.l a2,a1
        bsr     jx1_init
.loop:
        moveq   #16,d4                  ; fixed X, and X divides RING_SIZE
        bsr     jx1_resume
        moveq   #16,d6
        sub.w   d4,d6                   ; bytes emitted = requested - unspent
        movea.l a1,a4
        suba.l  d6,a4                   ; first output byte for this call
        ; consume [a4 .. a1)
        tst.w   d1
        beq.s   .done
        move.w  a1,d6
        and.w   #RING_SIZE-1,d6         ; aligned end has position zero
        bne.s   .loop
        movea.l a2,a1                   ; full and drained: wrap for next call
        bra.s   .loop
.done:
```

No bound register is passed to either entry. `RING_SIZE=32768` has its own
safe add-N encoding in the source because word address arithmetic sign
extends `$8000`.

Every call also emits exactly X bytes and leaves `d1.w <> 0`, except the final
one, which leaves `d1.w = 0` with whatever is left — `output mod X` bytes, or
a full budget when X divides the output exactly. A caller wanting fixed-size
blocks therefore gets them for free, a property the ST harness checks on
every call. Changing X between calls, choosing an X that does not divide N,
using a non-power-of-two size, or misaligning the base can read or write
outside the ring; use `jx1_68000_ring.S` when the caller cannot make every
promise.

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
