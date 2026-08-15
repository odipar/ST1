# Tests

Two layers. [emu/](emu/) is the differential suite under emulation — every
correctness claim about the decompressors comes from there, and it needs only
Python, Unicorn and rmac. This directory is the hardware layer, covering what
emulation cannot: real 68000 timing, and address errors that actually fault.

# Real-hardware validation

Two TOS programs exercise the decompressors on a real 68000 — under
[Hatari](https://hatari.tuxfamily.org/)'s cycle-exact Atari ST emulation, or on
actual silicon (`rmac -p` emits a plain `.PRG`; copy it to a floppy or Gotek
and run it). Both decompress embedded jx1 streams, verify every byte, and
measure decode time with the system's 200 Hz tick:

* [jx1_hatari.S](jx1_hatari.S) — [../jx1_68000.S](../jx1_68000.S), the linear
  decompressor
* [jx1_hatari_ring.S](jx1_hatari_ring.S) —
  [../jx1_68000_ring.S](../jx1_68000_ring.S), streaming each corpus through
  five dividing and non-dividing ring/chunk shapes. Nothing is accumulated:
  each call's output is compared against the expected image as it is drained.
  The point of the feature is visible here — 32000 bytes decompressed through
  a 256-byte buffer.

```sh
mvn compile                 # in the repo root: the compressor makes the streams
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

`run.sh` generates the corpora ([gendata.py](gendata.py) — the same seven the
emulator rig uses, same RNG stream), plus `-m256` streams for the smallest
ring and shared `-m1024` streams for fair timing. It assembles the linear and
general-ring variants with `rmac -p +o3`, then runs both under Hatari
headless with console output on stdout.

> **On `+o3`:** it used to matter — `jx1_68000.S` wrote
> `move.l d1,ctx_packed(a5)` with `ctx_packed = 0`, which vasm folded to
> `(a5)` on its own and rmac only with `+o3`. The packed `movem.l`
> initializer removed that operand, so rmac and vasm now agree byte for byte
> either way. The flag is kept because it costs nothing and the next such
> operand would otherwise cost two bytes silently.

## The corpora

Seven cases, the same ones (and the same RNG stream) the emulator rig uses.
Each is embedded normally, with `-m256` for the smallest ring, and with
`-m1024` for the shared N=1024 timing comparison.

| corpus | output | what it exercises |
|---|---:|---|
| text | 360 | short gammas, literals and matches mixed |
| wordsoup | 2925 | parse-heavy: many short ops |
| farmatch | 2900 | two-byte offsets |
| period129 | 1032 | the one/two-byte offset boundary |
| allsame | 1000 | one long match |
| rle32k | 32000 | ops near the 32K `dbf`/word limit |
| maxoffset | 33012 | offsets up to 32512; barely compressible |

"output" is the decompressed size — what the decompressor produces and what
the cycle counts below are spent on. Constrained `maxoffset` streams expand
because a small window on random data is nearly all literals. The timing
section keeps that compression cost separate from decoder overhead.

Both harnesses fill **the clobbered registers with junk before every
`jx1_resume`**. Both decoders share the same compact scratch ABI: `d3.w` is loaded
with the budget after its high word is poisoned, while `d4`/`d5`/`a2` remain
junk on entry. The ABI promises nothing about those incoming values, so this
is what a legal caller may look like.

## What it checks that emulation cannot

Each corpus is decompressed one-shot, resumed at chunk 16, 127 and 1, and then
one-shot into an **odd destination address**. A real 68000 raises an address
error on a misaligned word access, so that last case proves no copy path ever
widened its byte moves — Unicorn does not fault odd `.w`/`.l` accesses, so this
class of bug is invisible to the emulator rig.

Result: **all cases pass**, at every chunk size, at both destination parities.

## The ring's per-call contract, checked on hardware

The ring program runs 35 configurations (7 corpora × 5 ring/chunk shapes) and
checks every byte against the expected image — but it also verifies the
documented per-call size contract, which is where the ring/chunk ratio
matters:

| shape | ring % chunk | expected |
|---|---|---|
| R256/16 | 0 | every call a full chunk |
| R1024/16 | 0 | every call a full chunk |
| R256/127 | 2 | short calls at the wrap |
| R1000/16 | 8 | short calls at the wrap (and a ring that is not a power of two) |
| R1024/127 | 8 | short calls at the wrap |

Each call that leaves `d1.w` nonzero must produce exactly the chunk size —
unless the decoder ran into the end of the buffer, which the harness requires
to coincide with its saved end. The result is **`OKf`** when every call was a
full chunk and **`OKv`** when short calls appeared at the wrap.

```
text      R256/16=OKf R256/127=OKv R1000/16=OKf R1024/16=OKf R1024/127=OKf
wordsoup  R256/16=OKf R256/127=OKv R1000/16=OKv R1024/16=OKf R1024/127=OKv
rle32k    R256/16=OKf R256/127=OKv R1000/16=OKv R1024/16=OKf R1024/127=OKv
```

Every dividing shape reports `OKf`, exactly as documented. The non-dividing
shapes report `OKv` whenever the corpus is big enough to reach a wrap at all —
`text` (360 bytes) never wraps a 1000- or 1024-byte ring, so it stays `OKf`
there, and `allsame` (1000 bytes) exactly fills the 1000-byte ring without
wrapping.

## Current timing

<!-- cycle-timings:begin -->
<!-- Generated by emu/cycle_model.py; inputs 62a6a2909a38 -->
### Fair N=1024, X=16 comparison

Every decoder receives the exact same `-m1024` bytes. Linear means its
resumable entry at X=16, not the faster one-shot entry. The totals include
the decoder and only the control flow its harness needs to resume and wrap;
application-specific consumption is excluded for both. The ring cells show
the cycle cost relative to same-stream linear.

| corpus | output | stream | linear | general ring |
|---|---:|---:|---:|---:|
| text | 360 | 28 | 11,412 | 12,780 (+12.0%) |
| wordsoup | 2925 | 853 | 177,762 | 201,586 (+13.4%) |
| farmatch | 2900 | 410 | 75,798 | 85,164 (+12.4%) |
| period129 | 1032 | 138 | 28,058 | 31,446 (+12.1%) |
| allsame | 1000 | 6 | 26,544 | 29,912 (+12.7%) |
| rle32k | 32000 | 7 | 820,984 | 934,374 (+13.8%) |
| maxoffset | 33012 | 33108 | 870,344 | 918,610 (+5.5%) |

The model assembles the current sources and charges every executed
instruction using plain-MC68000 timings. Each cell is one non-final
iteration of the harness's timed core: setup, direct-label init/resume
calls, budget/result loop, ring wrapping, and the taken outer branch.
The final iteration is two cycles cheaper, so a complete run is
`iterations × cell - 2`. Tick-edge synchronization, OS interrupts,
wait states, and video-DMA contention are outside the model.

The same finite `run.sh` pass measured the comparison under cycle-exact
Hatari using the Atari ST's 200 Hz clock. Each value has ±1-tick
resolution; percentages here are
therefore less precise than the exact model above.

| corpus | repeats | linear ticks | general ring ticks |
|---|---:|---:|---:|
| text | 400 | 122 | 136 (+11.5%) |
| wordsoup | 30 | 142 | 162 (+14.1%) |
| farmatch | 60 | 121 | 135 (+11.6%) |
| period129 | 200 | 149 | 167 (+12.1%) |
| allsame | 200 | 141 | 158 (+12.1%) |
| rle32k | 6 | 131 | 148 (+13.0%) |
| maxoffset | 6 | 139 | 146 (+5.0%) |

### Compressor-window cost

This is a compressor trade-off, not decoder overhead. Sizes are recorded
separately so they cannot distort either comparison above.

| corpus | normal | `-m1024` (change) | `-m256` (change) |
|---|---:|---:|---:|
| text | 28 | 28 (0.0%) | 28 (0.0%) |
| wordsoup | 818 | 853 (+4.3%) | 1,203 (+47.1%) |
| farmatch | 212 | 410 (+93.4%) | 410 (+93.4%) |
| period129 | 138 | 138 (0.0%) | 138 (0.0%) |
| allsame | 6 | 6 (0.0%) | 6 (0.0%) |
| rle32k | 7 | 7 (0.0%) | 7 (0.0%) |
| maxoffset | 32589 | 33,108 (+1.6%) | 33,121 (+1.6%) |

A tick is 5 ms (40,000 nominal 8 MHz cycles); raw ticks
include interrupt and bus-contention time, while the model does not.

Regenerate both tables after any decoder, compressor, corpus, model, or
harness change:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh > /tmp/jx1-hatari.out
python3 68k/test/emu/cycle_model.py --write --hatari-output /tmp/jx1-hatari.out
python3 68k/test/emu/cycle_model.py --check
```

`audit.py` checks the recorded input fingerprint, so changing any timed
input without regenerating the model and hardware tables fails the normal
documentation audit.
<!-- cycle-timings:end -->
