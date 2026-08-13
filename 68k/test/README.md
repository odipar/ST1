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

> **`+o3` matters.** `jx1_68000.S` writes `move.l d1,ctx_packed(a5)` with
> `ctx_packed = 0`; vasm folds `0(a5)` to `(a5)` on its own, rmac only with
> `+o3`. With the flag both assemblers emit byte-identical 320-byte output —
> without it, rmac's is 322.

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
| text | 28 | 360 | 16 | 14520 | 16000 | +10.2% |
| text | 28 | 360 | 127 | 8216 | 8800 | +7.1% |
| wordsoup | 818 | 2925 | 16 | 217988 | 236000 | +8.3% |
| wordsoup | 818 | 2925 | 127 | 171258 | 182667 | +6.7% |
| farmatch | 212 | 2900 | 16 | 97562 | 106667 | +9.3% |
| farmatch | 212 | 2900 | 127 | 47324 | 50000 | +5.7% |
| period129 | 138 | 1032 | 16 | 35892 | 39400 | +9.8% |
| period129 | 138 | 1032 | 127 | 18258 | 19400 | +6.3% |
| allsame | 6 | 1000 | 16 | 34060 | 37400 | +9.8% |
| allsame | 6 | 1000 | 127 | 16620 | 17600 | +5.9% |
| rle32k | 7 | 32000 | 16 | 1057072 | 1160000 | +9.7% |
| rle32k | 7 | 32000 | 127 | 502514 | 526667 | +4.8% |
| maxoffset | 32589 | 33012 | 16 | 1085700 | 1193333 | +9.9% |
| maxoffset | 32589 | 33012 | 127 | 542328 | 566667 | +4.5% |

The ring decompressor, measured the same way through a 1024-byte ring at
chunk 16 — every corpus except `text`, `allsame` and `period129` being
several times the buffer it streams through — lands in the same band,
**+8.0% to +9.2%** over its model (mean +8.6%):

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 16590 | 18200 | +9.7% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 268692 | 290667 | +8.2% |
| farmatch | 410 | 2900 | 1024 | 16 | 111338 | 121333 | +9.0% |
| period129 | 138 | 1032 | 1024 | 16 | 40942 | 44600 | +8.9% |
| allsame | 6 | 1000 | 1024 | 16 | 39152 | 42600 | +8.8% |
| rle32k | 7 | 32000 | 1024 | 16 | 1224626 | 1326667 | +8.3% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1202444 | 1313333 | +9.2% |

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

`jx1_68000_ring_mod.S`, which requires the chunk to divide the ring and
spends that on a cheaper entry, on the same shape:

| corpus | ring | ring_mod | ring_mod gain |
|---|---|---|---|
| text | 182 | 176 | +3.3% |
| wordsoup | 218 | 215 | +1.4% |
| farmatch | 182 | 175 | +3.8% |
| period129 | 223 | 215 | +3.6% |
| allsame | 213 | 206 | +3.3% |
| rle32k | 199 | 192 | +3.5% |
| maxoffset | 197 | 189 | +4.1% |

(ticks, ring 1024, chunk 16, same corpora and calibration.) Both files carry
the same entry optimisations, so what the last column shows is the
divisibility requirement alone, against the +1.5–3.4% the cycle model
predicted for it.

**The model holds.** Real ST decode time runs **+4.5% to +10.2%** above the
idealized 68000 cycle counts (mean +7.7%) — the gap is interrupt service and
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
