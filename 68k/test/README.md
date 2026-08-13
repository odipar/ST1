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
  each corpus through several ring/chunk shapes. It builds twice:
  `-dRINGMOD=0` for [../jx1_68000_ring.S](../jx1_68000_ring.S) with dividing
  and non-dividing shapes, and `-dRINGMOD=1` for
  [../jx1_68000_ring_mod.S](../jx1_68000_ring_mod.S) with the dividing shapes
  its contract requires. Nothing is accumulated: each call's output is
  compared against the expected image as it is drained, and the wrap is
  detected the way the interface intends (`a1 == a4`). The point of the
  feature is visible here — 32000 bytes decompressed through a 256-byte
  buffer.

```sh
mvn compile                 # in the repo root: the compressor makes the streams
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

`run.sh` generates the corpora ([gendata.py](gendata.py) — the same seven the
emulator rig uses, same RNG stream, plus a `-m256` stream per corpus for the
ring), assembles both programs with `rmac -p +o3`, and runs them under Hatari
headless with console output on stdout.

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

Both harnesses fill **d0-d5 with junk before every `jx1_resume`**. The ABI
calls those registers clobbered, which promises nothing about their incoming
values, so this is what a legal caller may look like — and a decoder that
reads their upper words is broken. That check is what a partial-register bug
in both ring decoders escaped for want of, until an external audit found it.

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

`jx1_68000_ring_mod.S` requires the chunk to divide the ring, so its build
runs only dividing shapes — 256/16, 256/64, 1000/125, 1016/127, 1024/16,
1024/64, seven corpora, 42 configurations — and every one of them must report
`OKf`. It does, which is the fixed-size-output property confirmed on
hardware.

Each call that returns 1 must produce exactly the chunk size — unless it ran
into the end of the buffer, which the harness requires to coincide with the
write pointer reaching `a4`, and which it rejects outright when the chunk
divides the ring. The result is reported per shape: **`OKf`** when every call
was a full chunk, **`OKv`** when short calls appeared at the wrap.

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

## Timing vs the cycle model

The harness reports raw ticks plus a calibration loop of exactly known cycle
count, so the host can convert without assuming anything about the clock. A
200 Hz tick is 5 ms; at the ST's 8 MHz that is 40000 cycles. Cycles are per
full decode of one corpus: "stream" bytes in, "output" bytes out, at chunk
size X.

| corpus | stream | output | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|
| text | 28 | 360 | 16 | 14660 | 16000 | +9.1% |
| text | 28 | 360 | 127 | 8196 | 8800 | +7.4% |
| wordsoup | 818 | 2925 | 16 | 216648 | 233333 | +7.7% |
| wordsoup | 818 | 2925 | 127 | 168646 | 180000 | +6.7% |
| farmatch | 212 | 2900 | 16 | 98976 | 106667 | +7.8% |
| farmatch | 212 | 2900 | 127 | 47466 | 50000 | +5.3% |
| period129 | 138 | 1032 | 16 | 36368 | 39400 | +8.3% |
| period129 | 138 | 1032 | 127 | 18286 | 19400 | +6.1% |
| allsame | 6 | 1000 | 16 | 34536 | 37400 | +8.3% |
| allsame | 6 | 1000 | 127 | 16656 | 17600 | +5.7% |
| rle32k | 7 | 32000 | 16 | 1073044 | 1160000 | +8.1% |
| rle32k | 7 | 32000 | 127 | 504502 | 526667 | +4.4% |
| maxoffset | 32589 | 33012 | 16 | 1101916 | 1193333 | +8.3% |
| maxoffset | 32589 | 33012 | 127 | 544112 | 566667 | +4.1% |

The ring decompressor, measured the same way through a 1024-byte ring at
chunk 16 — every corpus except `text`, `allsame` and `period129` being
several times the buffer it streams through — lands in the same band,
**+6.4% to +7.7%** over its model (mean +7.0%):

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 16438 | 17700 | +7.7% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 264524 | 284000 | +7.4% |
| farmatch | 410 | 2900 | 1024 | 16 | 110600 | 118000 | +6.7% |
| period129 | 138 | 1032 | 1024 | 16 | 40634 | 43600 | +7.3% |
| allsame | 6 | 1000 | 1024 | 16 | 38868 | 41600 | +7.0% |
| rle32k | 7 | 32000 | 1024 | 16 | 1216098 | 1293333 | +6.4% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1197596 | 1280000 | +6.9% |

`jx1_68000_ring_mod.S`, which requires the chunk to divide the ring and
spends that on a cheaper entry, on the same shape. Its model column includes
**the caller's wrap** (`cmpa.l a4,a1 / bne.s / movea.l a3,a1`), since that
decoder does not wrap for you and the timed loop therefore executes it:

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 15932 | 17100 | +7.3% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 260510 | 280000 | +7.5% |
| farmatch | 410 | 2900 | 1024 | 16 | 106608 | 113333 | +6.3% |
| period129 | 138 | 1032 | 1024 | 16 | 39210 | 42000 | +7.1% |
| allsame | 6 | 1000 | 1024 | 16 | 37482 | 40000 | +6.7% |
| rle32k | 7 | 32000 | 1024 | 16 | 1172284 | 1246667 | +6.3% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1152380 | 1226667 | +6.4% |

Same band (+6.3% to +7.5%, mean +6.8%). Side by side, in raw ticks:

| corpus | ring | ring_mod | ring_mod gain |
|---|---|---|---|
| text | 177 | 171 | +3.4% |
| wordsoup | 213 | 210 | +1.4% |
| farmatch | 177 | 170 | +4.0% |
| period129 | 218 | 210 | +3.7% |
| allsame | 208 | 200 | +3.8% |
| rle32k | 194 | 187 | +3.6% |
| maxoffset | 192 | 184 | +4.2% |

(ticks, ring 1024, chunk 16, same corpora and calibration.) Both files carry
the same entry optimisations, so the last column is the divisibility
requirement alone — measured **+1.4% to +4.2%**, against the +1.5% to +3.8%
the cycle model predicts for it, and with the caller's wrap on ring_mod's
side of the ledger.

These tables also **confirm an optimisation on hardware independently of the
model**. Handing the write pointer to the caller — a1 in and out, instead of
a context field reloaded and stored every call — was predicted to be worth
about 1–4%. Measured on the same shape, the ticks fell from
181/216/181/223/213/199/197 to 177/213/177/218/208/194/192 for the ring
(**+1.4% to +2.5%**) and from 175/212/175/215/205/192/189 to
171/210/170/210/200/187/184 for ring_mod (**+0.9% to +2.9%**), while the
context shrank from 16 to 12 bytes.

**The model holds.** Real ST decode time runs **+4.1% to +9.1%** above the
idealized 68000 cycle counts (mean +7.0%) — the gap is interrupt service and
video-DMA bus contention, not decoder behaviour. For scale, the harness's own
reference `dbf` loop, whose cycle count is exact by construction, measures
**+22.6%** over its ideal on the same machine, and a `move.b (a0)+,(a1)+` loop
+12.0%: the decompressor loses *less* to the machine than either reference.

The model's *relative* predictions — the thing optimization decisions were
actually made on — hold within **1.6–4.8%**: predicted chunk-16 / chunk-127
ratios of 1.30–2.21 against 1.32–2.31 measured.

Measurement resolution is ±1 tick, i.e. 0.4–1.3% per figure; the calibration
loop itself lands on 240 or 241 ticks depending on where the program's code
falls relative to the interrupts. Hatari settings:
`--machine st --cpuclock 8 --cpu-exact on --compatible on` (cycle-exact 68000
with prefetch), plus `--disable-video 1` to run headless — that flag only
suppresses the host window, the shifter still contends for the bus and every
measured tick is identical to a windowed run.
