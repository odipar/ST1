# Real-hardware validation

Two TOS programs exercise the decompressors on a real 68000 — under
[Hatari](https://hatari.tuxfamily.org/)'s cycle-exact Atari ST emulation, or on
actual silicon (`rmac -p` emits a plain `.PRG`; copy it to a floppy or Gotek
and run it). Both decompress embedded jx1 streams, verify every byte, and
measure decode time with the system's 200 Hz tick:

* [jx1_hatari.S](jx1_hatari.S) — [../jx1_68000.S](../jx1_68000.S), the linear
  decompressor
* [jx1_hatari_ring.S](jx1_hatari_ring.S) — the ring decompressors, streaming
  each corpus through several ring/chunk shapes. It builds three times:
  `-dRINGMOD=0` for [../jx1_68000_ring.S](../jx1_68000_ring.S) with dividing
  and non-dividing shapes, `-dRINGMOD=1` for
  [../jx1_68000_ring_mod.S](../jx1_68000_ring_mod.S) and `-dRINGMOD=2` for
  [../jx1_68000_ring_mod_opt.S](../jx1_68000_ring_mod_opt.S), both with the
  dividing shapes their contract requires. Nothing is accumulated: each call's output is
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

> **`+o3` matters.** `jx1_68000.S` writes `move.l d1,ctx_packed(a5)` with
> `ctx_packed = 0`; vasm folds `0(a5)` to `(a5)` on its own, rmac only with
> `+o3`. With the flag both assemblers emit byte-identical 324-byte output —
> without it, rmac's is 326.

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
| text | 28 | 360 | 16 | 15366 | 16900 | +10.0% |
| text | 28 | 360 | 127 | 8342 | 9000 | +7.9% |
| wordsoup | 818 | 2925 | 16 | 228410 | 246667 | +8.0% |
| wordsoup | 818 | 2925 | 127 | 175616 | 186667 | +6.3% |
| farmatch | 212 | 2900 | 16 | 104096 | 113333 | +8.9% |
| farmatch | 212 | 2900 | 127 | 48134 | 50667 | +5.3% |
| period129 | 138 | 1032 | 16 | 38226 | 41800 | +9.3% |
| period129 | 138 | 1032 | 127 | 18576 | 19600 | +5.5% |
| allsame | 6 | 1000 | 16 | 36298 | 39800 | +9.6% |
| allsame | 6 | 1000 | 127 | 16878 | 17800 | +5.5% |
| rle32k | 7 | 32000 | 16 | 1129042 | 1233333 | +9.2% |
| rle32k | 7 | 32000 | 127 | 511556 | 533333 | +4.3% |
| maxoffset | 32589 | 33012 | 16 | 1160802 | 1266667 | +9.1% |
| maxoffset | 32589 | 33012 | 127 | 552446 | 580000 | +5.0% |

The ring decompressor, measured the same way through a 1024-byte ring at
chunk 16 — every corpus except `text`, `allsame` and `period129` being
several times the buffer it streams through — lands in the same band,
**+8.0% to +9.2%** over its model (mean +8.6%):

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 17894 | 19500 | +9.0% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 281588 | 304000 | +8.0% |
| farmatch | 410 | 2900 | 1024 | 16 | 122090 | 132667 | +8.7% |
| period129 | 138 | 1032 | 1024 | 16 | 44740 | 48600 | +8.6% |
| allsame | 6 | 1000 | 1024 | 16 | 42742 | 46400 | +8.6% |
| rle32k | 7 | 32000 | 1024 | 16 | 1340624 | 1453333 | +8.4% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1343450 | 1466667 | +9.2% |

`jx1_68000_ring_mod.S`, which requires the chunk to divide the ring and
spends that on a cheaper entry, measured on the same shape:

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 17388 | 19000 | +9.3% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 277538 | 298667 | +7.6% |
| farmatch | 410 | 2900 | 1024 | 16 | 118062 | 128000 | +8.4% |
| period129 | 138 | 1032 | 1024 | 16 | 43298 | 47000 | +8.6% |
| allsame | 6 | 1000 | 1024 | 16 | 41356 | 45000 | +8.8% |
| rle32k | 7 | 32000 | 1024 | 16 | 1296252 | 1400000 | +8.0% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1297658 | 1413333 | +8.9% |

Same band (+7.6% to +9.3%, mean +8.5%), and the two tables also **confirm the
optimisation on hardware independently of the model**: at identical corpora,
ring and chunk, the measured ticks fall from 195/228/199/243/232/218/220 to
190/224/192/235/225/210/212, a gain of **+1.8% to +3.7%** against the +1.5% to
+3.4% the model predicted — agreement within the ±1 tick resolution.

`jx1_68000_ring_mod_opt.S`, the cycle-tuned build of the same contract, on the
same shape — and the three ring rows together confirm each optimisation step
on hardware, independently of the model:

| corpus | ring | ring_mod | ring_mod_opt | mod_opt vs mod |
|---|---|---|---|---|
| text | 195 | 190 | 176 | +7.4% |
| wordsoup | 228 | 224 | 215 | +4.0% |
| farmatch | 199 | 192 | 175 | +8.9% |
| period129 | 243 | 235 | 215 | +8.5% |
| allsame | 232 | 225 | 206 | +8.4% |
| rle32k | 218 | 210 | 192 | +8.6% |
| maxoffset | 220 | 212 | 189 | +10.8% |

(ticks, ring 1024, chunk 16, same corpora and calibration). The measured
+4.0–10.8% sits against the +4.8–11.0% the cycle model predicted.

**The model holds.** Real ST decode time runs **+4.3% to +10.0%** above the
idealized 68000 cycle counts (mean +7.4%) — the gap is interrupt service and
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
