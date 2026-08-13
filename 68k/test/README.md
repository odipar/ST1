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
  256- and 1024-byte rings at chunk 16 and 127. Nothing is accumulated: each
  call's output is compared against the expected image as it is drained, and
  the wrap is detected the way the interface intends (`a1 == a4`). The point
  of the feature is visible here — 32000 bytes decompressed through a
  256-byte buffer.

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

## What it checks that emulation cannot

Each corpus is decompressed one-shot, resumed at chunk 16, 127 and 1, and then
one-shot into an **odd destination address**. A real 68000 raises an address
error on a misaligned word access, so that last case proves no copy path ever
widened its byte moves — Unicorn does not fault odd `.w`/`.l` accesses, so this
class of bug is invisible to the emulator rig.

Result: **all cases pass**, at every chunk size, at both destination parities.
The ring program passes all 28 of its configurations too (7 corpora × 2 ring
sizes × 2 chunk sizes), every byte checked against the expected image.

## Timing vs the cycle model

The harness reports raw ticks plus a calibration loop of exactly known cycle
count, so the host can convert without assuming anything about the clock. A
200 Hz tick is 5 ms; at the ST's 8 MHz that is 40000 cycles.

| corpus | X | model | ST measured | ST vs model |
|---|---|---|---|---|
| text | 16 | 15366 | 16900 | +10.0% |
| text | 127 | 8342 | 9000 | +7.9% |
| wordsoup | 16 | 228410 | 246667 | +8.0% |
| wordsoup | 127 | 175616 | 186667 | +6.3% |
| farmatch | 16 | 104096 | 113333 | +8.9% |
| farmatch | 127 | 48134 | 50667 | +5.3% |
| period129 | 16 | 38226 | 41800 | +9.3% |
| period129 | 127 | 18576 | 19600 | +5.5% |
| allsame | 16 | 36298 | 39800 | +9.6% |
| allsame | 127 | 16878 | 17800 | +5.5% |
| rle32k | 16 | 1129042 | 1233333 | +9.2% |
| rle32k | 127 | 511556 | 533333 | +4.3% |
| maxoffset | 16 | 1160802 | 1266667 | +9.1% |
| maxoffset | 127 | 552446 | 580000 | +5.0% |

The ring decompressor, measured the same way at ring 1024 / chunk 16, lands
in the same band — **+8.0% to +9.2%** over its model (mean +8.6%):

| corpus | model | ST measured | ST vs model |
|---|---|---|---|
| text | 17894 | 19500 | +9.0% |
| wordsoup | 281588 | 304000 | +8.0% |
| farmatch | 122090 | 132667 | +8.7% |
| period129 | 44740 | 48600 | +8.6% |
| allsame | 42742 | 46400 | +8.6% |
| rle32k | 1340624 | 1453333 | +8.4% |
| maxoffset | 1343450 | 1466667 | +9.2% |

**The model holds.** Real ST decode time runs **+4.3% to +10.0%** above the
idealized 68000 cycle counts (mean +7.4%) — the gap is interrupt service and
video-DMA bus contention, not decoder behaviour. For scale, the harness's own
reference `dbf` loop, whose cycle count is exact by construction, measures
**+22.6%** over its ideal on the same machine, and a `move.b (a0)+,(a1)+` loop
+12.0%: the decompressor loses *less* to the machine than either reference.

The model's *relative* predictions — the thing optimization decisions were
actually made on — hold within **1.6–4.8%**: predicted chunk-16 / chunk-127
ratios of 1.30–2.21 against 1.32–2.31 measured.

Measurement resolution is ±1 tick, i.e. 0.4–1.3% per figure. Hatari settings:
`--machine st --cpuclock 8 --cpu-exact on --compatible on` (cycle-exact 68000
with prefetch), plus `--disable-video 1` to run headless — that flag only
suppresses the host window, the shifter still contends for the bus and every
measured tick is identical to a windowed run.
