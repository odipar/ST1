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
* [jx1_hatari_ring.S](jx1_hatari_ring.S) — the ring decompressors, streaming
  each corpus through several ring/chunk shapes. It builds once with
  `-dRINGMOD=0` for [../jx1_68000_ring.S](../jx1_68000_ring.S), including
  dividing and non-dividing shapes, and twice with `-dRINGMOD=1` for
  [../jx1_68000_ring_mod.S](../jx1_68000_ring_mod.S), at compile-time
  `RING_SIZE` values 256 and 1024. Nothing is accumulated: each call's output
  is compared against the expected image as it is drained, and wrap is
  detected against the harness's saved ring end. The point of the feature is
  visible here — 32000 bytes decompressed through a 256-byte buffer.

```sh
mvn compile                 # in the repo root: the compressor makes the streams
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

`run.sh` generates the corpora ([gendata.py](gendata.py) — the same seven the
emulator rig uses, same RNG stream, plus a `-m256` stream per corpus for the
ring), assembles the linear, general-ring and two fixed-ring variants with
`rmac -p +o3`, and runs them under Hatari headless with console output on
stdout.

> **On `+o3`:** it used to matter — `jx1_68000.S` wrote
> `move.l d1,ctx_packed(a5)` with `ctx_packed = 0`, which vasm folded to
> `(a5)` on its own and rmac only with `+o3`. The packed `movem.l`
> initializer removed that operand, so rmac and vasm now agree byte for byte
> either way. The flag is kept because it costs nothing and the next such
> operand would otherwise cost two bytes silently.

## The corpora

Seven cases, the same ones (and the same RNG stream) the emulator rig uses.
Each is embedded twice: compressed normally, and compressed with `-m256` so
every offset fits the smallest ring the harness tests.

| corpus | output | stream | stream (`-m256`) | what it exercises |
|---|---|---|---|---|
| text | 360 | 28 | 28 | short gammas, literals and matches mixed |
| wordsoup | 2925 | 818 | 1203 | parse-heavy: many short ops |
| farmatch | 2900 | 212 | 410 | two-byte offsets |
| period129 | 1032 | 138 | 138 | the one/two-byte offset boundary |
| allsame | 1000 | 6 | 6 | one long match |
| rle32k | 32000 | 7 | 7 | ops near the 32K `dbf`/word limit |
| maxoffset | 33012 | 32589 | 33121 | offsets up to 32512; barely compressible |

"output" is the decompressed size — what the decompressor produces and what
the cycle counts below are spent on. Note `maxoffset` at `-m256` *expands*
(33121 > 33012): a 256-byte window on random data is nearly all literals,
which is exactly the ratio cost of a small ring.

Both harnesses fill **the clobbered registers with junk before every
`jx1_resume`**. All three now share the same compact ABI: `d3.w` is loaded
with the budget after its high word is poisoned, while `d4`/`d5`/`a2` remain
junk on entry. The ABI promises nothing about those incoming values, so this
is what a legal caller may look like, and a decoder that reads stale upper
words is broken. That check is what a partial-register bug in both ring
decoders escaped for want of, until an external audit found it.

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

`jx1_68000_ring_mod.S` is assembled for a power-of-two `RING_SIZE`, requires
the buffer to have matching alignment, and requires one fixed chunk X to
divide that size. The harness builds N=256 and N=1024 and runs X=16 and X=64
for each: seven corpora, 28 configurations. Every one must report `OKf`; this
confirms the fixed-size-output property for multiple compiled sizes on
hardware.

Each call that leaves `d1.w` nonzero must produce exactly the chunk size —
unless the general decoder ran into the end of the buffer, which the harness
requires to coincide with the harness's saved end. The
fixed decoder rejects such a short call outright. The result is reported per
shape: **`OKf`** when every call was a full chunk, **`OKv`** when short calls
appeared at the wrap.

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
<!-- Generated by emu/cycle_model.py; inputs 3af6e75d2d3e -->
The model assembles the current sources and charges every executed
instruction using plain-MC68000 timings. Each cell is one non-final
iteration of the harness's timed core: setup, direct-label init/resume
calls, budget/result loop, ring wrapping, and the taken outer branch.
The final iteration is two cycles cheaper, so a complete run is
`iterations × cell - 2`. Tick-edge synchronization, OS interrupts,
wait states, and video-DMA contention are outside the model.

Linear uses the normal streams. Both rings use `-m256` streams; ring
rows are X=16 and the fixed ring is assembled separately for each N.

| corpus | output | stream | linear X16 | linear X127 |
|---|---:|---:|---:|---:|
| text | 360 | 28 | 11,576 | 7,464 |
| wordsoup | 2925 | 818 | 171,626 | 142,066 |
| farmatch | 2900 | 212 | 77,440 | 44,604 |
| period129 | 1032 | 138 | 28,572 | 17,042 |
| allsame | 1000 | 6 | 27,046 | 15,656 |
| rle32k | 32000 | 7 | 836,982 | 474,704 |
| maxoffset | 33012 | 32589 | 870,390 | 511,234 |

| corpus | stream `-m256` | general N1024 | `ring_mod` N256 | `ring_mod` N1024 |
|---|---:|---:|---:|---:|
| text | 28 | 13,524 | 13,392 | 13,132 |
| wordsoup | 1203 | 212,670 | 210,430 | 206,186 |
| farmatch | 410 | 90,550 | 89,604 | 87,890 |
| period129 | 138 | 33,376 | 33,610 | 32,398 |
| allsame | 6 | 31,930 | 31,558 | 30,922 |
| rle32k | 7 | 996,392 | 983,382 | 963,648 |
| maxoffset | 33121 | 964,728 | 957,866 | 955,418 |

The same finite `run.sh` pass produced these raw 200 Hz ticks, in
corpus order `text/wordsoup/farmatch/period129/allsame/rle32k/maxoffset`:

| decoder | N/X | iterations | ST ticks |
|---|---|---|---|
| linear | —/16 | 400/30/60/200/200/6/6 | 124/137/123/152/143/133/139 |
| linear | —/127 | 400/30/60/200/200/6/6 | 78/113/69/89/81/74/80 |
| general ring | 1024/16 | 400/30/60/200/200/6/6 | 144/171/144/178/170/159/155 |
| `ring_mod` | 256/16 | 400/30/60/200/200/6/6 | 143/170/142/178/167/156/152 |
| `ring_mod` | 1024/16 | 400/30/60/200/200/6/6 | 140/166/139/171/163/153/152 |

A tick is 5 ms (40,000 nominal 8 MHz cycles), and each displayed
measurement has ±1-tick resolution. Raw ticks include interrupt and
bus-contention time; the model does not.

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
